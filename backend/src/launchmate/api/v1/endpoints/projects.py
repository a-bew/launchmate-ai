from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime
import uuid
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project, ProjectStatus, ProjectLockStatus
from ....models.version import Version, VersionType
from ....core.exceptions import NotFoundError
from ....tasks.generation_tasks import generate_initial_project, regenerate_section

router = APIRouter()

class ProjectCreate(BaseModel):
    core_premise: str
    primary_market: str
    initial_budget: int
    budget_label: str
    market_vectors: List[str]

class ProjectResponse(BaseModel):
    id: str
    name: str
    status: str
    completion: int
    version_count: int
    lock_status: str
    market_vectors: List[str]
    created_at: datetime
    updated_at: datetime

class ProjectDetailResponse(ProjectResponse):
    parameters: dict
    sections: dict
    open_threads_count: int

class ProjectListResponse(BaseModel):
    data: List[ProjectResponse]
    total: int
    page: int
    per_page: int
    total_pages: int

class ProjectUpdate(BaseModel):
    core_premise: Optional[str] = None
    primary_market: Optional[str] = None
    initial_budget: Optional[int] = None
    market_vectors: Optional[List[str]] = None
    create_version: bool = True

async def get_project_or_404(project_id: str, user_id: str, db: AsyncSession) -> Project:
    result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    return project

def generate_project_name() -> str:
    return "Untitled Project"

def calculate_completion(project: Project) -> int:
    return 0

@router.get("/", response_model=ProjectListResponse)
async def list_projects(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    query = select(Project).where(Project.owner_id == current_user.id)
    total_result = await db.execute(select(func.count()).select_from(query.subquery()))
    total = total_result.scalar()
    query = query.offset((page - 1) * per_page).limit(per_page)
    result = await db.execute(query)
    projects = result.scalars().all()
    data = []
    for p in projects:
        ver_count = await db.execute(select(func.count(Version.id)).where(Version.project_id == p.id))
        version_count = ver_count.scalar() or 0
        data.append(ProjectResponse(
            id=p.public_id,
            name=p.name,
            status=p.status.value,
            completion=calculate_completion(p),
            version_count=version_count,
            lock_status=p.lock_status.value,
            market_vectors=p.market_vectors,
            created_at=p.created_at,
            updated_at=p.updated_at,
        ))
    return ProjectListResponse(
        data=data,
        total=total,
        page=page,
        per_page=per_page,
        total_pages=(total + per_page - 1) // per_page
    )

@router.post("/", status_code=201)
async def create_project(
    data: ProjectCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    project_id = str(uuid.uuid4())
    public_id = f"prj_{uuid.uuid4().hex[:8]}"
    name = generate_project_name()
    project = Project(
        id=project_id,
        public_id=public_id,
        owner_id=current_user.id,
        name=name,
        status=ProjectStatus.IDEATION,
        lock_status=ProjectLockStatus.UNLOCKED,
        core_premise=data.core_premise,
        primary_market=data.primary_market,
        initial_budget=data.initial_budget,
        budget_label=data.budget_label,
        market_vectors=data.market_vectors,
    )
    db.add(project)
    await db.flush()
    version_id = str(uuid.uuid4())
    version_public_id = f"ver_{uuid.uuid4().hex[:8]}"
    version = Version(
        id=version_id,
        public_id=version_public_id,
        project_id=project.id,
        label="Initial generation",
        type=VersionType.VERSION,
        number=1,
        changes={},
    )
    db.add(version)
    project.current_version_id = version_id
    await db.commit()
    # Queue Celery task
    task = generate_initial_project.delay(project_id)
    project.celery_task_id = task.id
    await db.commit()
    return {
        "id": public_id,
        "name": name,
        "status": "ideation",
        "completion": 0,
        "version_id": version_public_id,
        "generation_job_id": task.id,
        "message": "Project initialized. Generation in progress."
    }

@router.get("/{project_id}", response_model=ProjectDetailResponse)
async def get_project(
    project_id: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    project = await get_project_or_404(project_id, current_user.id, db)
    ver_count = await db.execute(select(func.count(Version.id)).where(Version.project_id == project.id))
    version_count = ver_count.scalar() or 0
    from ....models.thread import Thread
    thread_count = await db.execute(select(func.count(Thread.id)).where(Thread.project_id == project.id, Thread.status == "open"))
    open_threads = thread_count.scalar() or 0
    return ProjectDetailResponse(
        id=project.public_id,
        name=project.name,
        status=project.status.value,
        completion=calculate_completion(project),
        version_count=version_count,
        current_version_id=project.current_version_id or "",
        lock_status=project.lock_status.value,
        market_vectors=project.market_vectors,
        created_at=project.created_at,
        updated_at=project.updated_at,
        parameters={
            "core_premise": project.core_premise,
            "primary_market": project.primary_market,
            "initial_budget": project.initial_budget,
            "budget_label": project.budget_label,
        },
        sections={},
        open_threads_count=open_threads,
    )

@router.patch("/{project_id}")
async def update_project(
    project_id: str,
    data: ProjectUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    project = await get_project_or_404(project_id, current_user.id, db)
    regeneration_required = []
    if data.core_premise and data.core_premise != project.core_premise:
        project.core_premise = data.core_premise
        regeneration_required = ["market_research", "financials", "brand_kit", "tech_setup"]
    if data.primary_market and data.primary_market != project.primary_market:
        project.primary_market = data.primary_market
        if "market_research" not in regeneration_required:
            regeneration_required.append("market_research")
        if "brand_kit" not in regeneration_required:
            regeneration_required.append("brand_kit")
    if data.initial_budget and data.initial_budget != project.initial_budget:
        project.initial_budget = data.initial_budget
        if "financials" not in regeneration_required:
            regeneration_required.append("financials")
    if data.market_vectors and data.market_vectors != project.market_vectors:
        project.market_vectors = data.market_vectors
        if "market_research" not in regeneration_required:
            regeneration_required.append("market_research")
        if "financials" not in regeneration_required:
            regeneration_required.append("financials")
    if data.create_version and regeneration_required:
        old_version_id = project.current_version_id
        new_version_id = str(uuid.uuid4())
        new_version_public_id = f"ver_{uuid.uuid4().hex[:8]}"
        max_num = await db.execute(select(func.max(Version.number)).where(Version.project_id == project.id, Version.type == VersionType.VERSION))
        max_num = max_num.scalar() or 0
        new_number = max_num + 1
        new_version = Version(
            id=new_version_id,
            public_id=new_version_public_id,
            project_id=project.id,
            parent_version_id=old_version_id,
            label=f"Parameter update v{new_number}",
            type=VersionType.VERSION,
            number=new_number,
            changes={"updated_params": data.dict(exclude_unset=True)},
        )
        db.add(new_version)
        # Clone section data
        from ....models.market_research import MarketResearch
        from ....models.financials import Financials
        from ....models.brand_kit import BrandKit
        from ....models.tech_setup import TechSetup
        for model in [MarketResearch, Financials, BrandKit, TechSetup]:
            old_rec = await db.execute(select(model).where(model.version_id == old_version_id))
            old_rec = old_rec.scalar_one_or_none()
            if old_rec:
                new_rec = model(version_id=new_version_id)
                for col in model.__table__.columns:
                    if col.name not in ["id", "version_id", "updated_at"]:
                        setattr(new_rec, col.name, getattr(old_rec, col.name))
                db.add(new_rec)
        project.current_version_id = new_version_id
        await db.flush()
        for section in regeneration_required:
            regenerate_section.delay(project.id, section, new_version_id)
    await db.commit()
    return {
        "id": project.public_id,
        "new_version_id": project.current_version_id,
        "version_count": 0,
        "updated_at": project.updated_at.isoformat(),
        "regeneration_required": regeneration_required,
        "message": "Parameters updated. New version created."
    }

@router.delete("/{project_id}")
async def delete_project(
    project_id: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    project = await get_project_or_404(project_id, current_user.id, db)
    await db.delete(project)
    await db.commit()
    return {"message": "Project deleted", "id": project_id}
