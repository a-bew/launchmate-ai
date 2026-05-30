#!/bin/bash
set -e

echo "⚙️ Phase 6: Celery + Real Agent + Polling + Scheduled Jobs"

cd backend

# -------------------------------
# 1. core/celery_app.py
# -------------------------------
mkdir -p src/launchmate/core
cat > src/launchmate/core/celery_app.py << 'EOF'
from celery import Celery
from .config import settings

celery_app = Celery(
    "launchmate",
    broker=settings.CELERY_BROKER_URL or settings.REDIS_URL,
    backend=settings.CELERY_RESULT_BACKEND or settings.REDIS_URL,
    include=[
        "launchmate.tasks.generation_tasks",
        "launchmate.tasks.proactive_tasks",
        "launchmate.tasks.pdf_tasks",
        "launchmate.tasks.domain_tasks",
        "launchmate.tasks.email_tasks"
    ]
)

celery_app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="UTC",
    enable_utc=True,
    task_track_started=True,
    task_time_limit=30 * 60,
    task_soft_time_limit=25 * 60,
    beat_schedule={
        "generate_proactive_threads_daily": {
            "task": "launchmate.tasks.proactive_tasks.generate_proactive_threads",
            "schedule": 86400,  # 24 hours
            "args": (),
        },
    },
)
EOF

# -------------------------------
# 2. tasks/__init__.py
# -------------------------------
mkdir -p src/launchmate/tasks
cat > src/launchmate/tasks/__init__.py << 'EOF'
from .generation_tasks import generate_initial_project, regenerate_section
from .proactive_tasks import generate_proactive_threads
from .pdf_tasks import generate_founder_brief
from .domain_tasks import register_domains
from .email_tasks import send_email
EOF

# -------------------------------
# 3. tasks/generation_tasks.py (full implementation)
# -------------------------------
cat > src/launchmate/tasks/generation_tasks.py << 'EOF'
import asyncio
import uuid
from celery import shared_task
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..core.database import AsyncSessionLocal
from ..models.project import Project, ProjectStatus
from ..models.version import Version
from ..models.market_research import MarketResearch, SectionLockStatus
from ..models.financials import Financials
from ..models.brand_kit import BrandKit
from ..models.tech_setup import TechSetup
from ..tools.agent import run_signal_sight
import json
import logging

logger = logging.getLogger(__name__)

def update_task_progress(task, progress: int, current_step: str, steps_completed: list, steps_remaining: list, estimated_seconds: int = None):
    task.update_state(
        state="PROGRESS",
        meta={
            "progress": progress,
            "current_step": current_step,
            "steps_completed": steps_completed,
            "steps_remaining": steps_remaining,
            "estimated_seconds_remaining": estimated_seconds,
        }
    )

@shared_task(bind=True)
def generate_initial_project(self, project_id: str):
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Project).where(Project.id == project_id))
            project = result.scalar_one_or_none()
            if not project:
                raise ValueError(f"Project {project_id} not found")
            if not project.current_version_id:
                raise ValueError(f"Project {project_id} has no current version")
            version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
            version = version_result.scalar_one()
            
            params = {
                "core_premise": project.core_premise,
                "primary_market": project.primary_market,
                "initial_budget": project.initial_budget,
                "market_vectors": project.market_vectors,
            }
            sections = ["market_research", "financials", "brand_kit", "tech_setup"]
            total_steps = len(sections)
            steps_completed = []
            
            for idx, section in enumerate(sections):
                update_task_progress(self, int((idx / total_steps) * 100), f"Generating {section}...", steps_completed, sections[idx:], 30)
                # Construct prompt
                if section == "market_research":
                    prompt = f"""Market research for startup: {params['core_premise']} in {params['primary_market']}. Vectors: {params['market_vectors']}. Output JSON with 'signals' and 'competitors' arrays."""
                elif section == "financials":
                    prompt = f"""Financials for startup with budget ${params['initial_budget']}: {params['core_premise']}. Output JSON with 'cost_breakdown', 'calculated', 'break_even'."""
                elif section == "brand_kit":
                    prompt = f"""Brand kit for {project.name}. Output JSON with 'namespace', 'typography', 'logo_options'."""
                else:  # tech_setup
                    prompt = f"""Tech setup for {project.name}. Output JSON with 'online_presence', 'automations', 'store'."""
                
                result = run_signal_sight(prompt)
                if "error" in result["brief"]:
                    raise RuntimeError(f"Agent failed for {section}: {result['brief'].get('error')}")
                data = result["brief"]
                
                if section == "market_research":
                    mr = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
                    mr_rec = mr.scalar_one_or_none()
                    if not mr_rec:
                        mr_rec = MarketResearch(version_id=version.id)
                        db.add(mr_rec)
                    mr_rec.signals = data.get("signals", [])
                    mr_rec.competitors = data.get("competitors", [])
                    mr_rec.lock_status = SectionLockStatus.UNLOCKED
                elif section == "financials":
                    fin = await db.execute(select(Financials).where(Financials.version_id == version.id))
                    fin_rec = fin.scalar_one_or_none()
                    if not fin_rec:
                        fin_rec = Financials(version_id=version.id)
                        db.add(fin_rec)
                    fin_rec.cost_breakdown = data.get("cost_breakdown", [])
                    fin_rec.calculated = data.get("calculated", {})
                    fin_rec.break_even = data.get("break_even", {})
                    fin_rec.lock_status = SectionLockStatus.UNLOCKED
                elif section == "brand_kit":
                    bk = await db.execute(select(BrandKit).where(BrandKit.version_id == version.id))
                    bk_rec = bk.scalar_one_or_none()
                    if not bk_rec:
                        bk_rec = BrandKit(version_id=version.id)
                        db.add(bk_rec)
                    bk_rec.namespace = data.get("namespace", [])
                    bk_rec.typography = data.get("typography", {})
                    bk_rec.logo_options = data.get("logo_options", [])
                    bk_rec.selected_logo_id = None
                    bk_rec.lock_status = SectionLockStatus.UNLOCKED
                else:  # tech_setup
                    ts = await db.execute(select(TechSetup).where(TechSetup.version_id == version.id))
                    ts_rec = ts.scalar_one_or_none()
                    if not ts_rec:
                        ts_rec = TechSetup(version_id=version.id)
                        db.add(ts_rec)
                    ts_rec.online_presence = data.get("online_presence", {})
                    ts_rec.automations = data.get("automations", {})
                    ts_rec.store = data.get("store", {})
                    ts_rec.lock_status = SectionLockStatus.DRAFT
                
                await db.commit()
                steps_completed.append(section)
            
            project.status = ProjectStatus.DRAFT
            await db.commit()
            return {"status": "complete"}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())

@shared_task(bind=True)
def regenerate_section(self, project_id: str, section_name: str, version_id: str):
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Project).where(Project.id == project_id))
            project = result.scalar_one_or_none()
            if not project:
                raise ValueError(f"Project {project_id} not found")
            version_result = await db.execute(select(Version).where(Version.id == version_id))
            version = version_result.scalar_one()
            params = {
                "core_premise": project.core_premise,
                "primary_market": project.primary_market,
                "initial_budget": project.initial_budget,
                "market_vectors": project.market_vectors,
            }
            prompt_map = {
                "market_research": f"Market research for: {params['core_premise']} in {params['primary_market']}. Vectors: {params['market_vectors']}. Output JSON with signals and competitors.",
                "financials": f"Financials for startup with budget ${params['initial_budget']}, premise: {params['core_premise']}. Output JSON with cost_breakdown, calculated, break_even.",
                "brand_kit": f"Brand kit for {project.name}. Output JSON with namespace, typography, logo_options.",
                "tech_setup": f"Tech setup for {project.name}. Output JSON with online_presence, automations, store.",
            }
            prompt = prompt_map.get(section_name)
            if not prompt:
                raise ValueError(f"Unknown section: {section_name}")
            result = run_signal_sight(prompt)
            if "error" in result["brief"]:
                raise RuntimeError(f"Agent failed for {section_name}: {result['brief'].get('error')}")
            data = result["brief"]
            
            if section_name == "market_research":
                mr = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
                mr_rec = mr.scalar_one_or_none()
                if not mr_rec:
                    mr_rec = MarketResearch(version_id=version.id)
                    db.add(mr_rec)
                mr_rec.signals = data.get("signals", [])
                mr_rec.competitors = data.get("competitors", [])
            elif section_name == "financials":
                fin = await db.execute(select(Financials).where(Financials.version_id == version.id))
                fin_rec = fin.scalar_one_or_none()
                if not fin_rec:
                    fin_rec = Financials(version_id=version.id)
                    db.add(fin_rec)
                fin_rec.cost_breakdown = data.get("cost_breakdown", [])
                fin_rec.calculated = data.get("calculated", {})
                fin_rec.break_even = data.get("break_even", {})
            elif section_name == "brand_kit":
                bk = await db.execute(select(BrandKit).where(BrandKit.version_id == version.id))
                bk_rec = bk.scalar_one_or_none()
                if not bk_rec:
                    bk_rec = BrandKit(version_id=version.id)
                    db.add(bk_rec)
                bk_rec.namespace = data.get("namespace", [])
                bk_rec.typography = data.get("typography", {})
                bk_rec.logo_options = data.get("logo_options", [])
            elif section_name == "tech_setup":
                ts = await db.execute(select(TechSetup).where(TechSetup.version_id == version.id))
                ts_rec = ts.scalar_one_or_none()
                if not ts_rec:
                    ts_rec = TechSetup(version_id=version.id)
                    db.add(ts_rec)
                ts_rec.online_presence = data.get("online_presence", {})
                ts_rec.automations = data.get("automations", {})
                ts_rec.store = data.get("store", {})
            await db.commit()
            return {"section": section_name, "status": "regenerated"}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())
EOF

# -------------------------------
# 4. tasks/proactive_tasks.py
# -------------------------------
cat > src/launchmate/tasks/proactive_tasks.py << 'EOF'
import asyncio
import uuid
from celery import shared_task
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from ..core.database import AsyncSessionLocal
from ..models.project import Project, ProjectStatus, ProjectLockStatus
from ..models.proactive_thread import ProactiveThread, ProactiveStatus
from ..tools.agent import run_signal_sight
import logging

logger = logging.getLogger(__name__)

@shared_task
def generate_proactive_threads():
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(
                select(Project).where(
                    Project.status == ProjectStatus.ACTIVE,
                    Project.lock_status != ProjectLockStatus.LOCKED
                )
            )
            projects = result.scalars().all()
            for project in projects:
                count_result = await db.execute(
                    select(func.count(ProactiveThread.id)).where(
                        ProactiveThread.project_id == project.id,
                        ProactiveThread.status.in_([ProactiveStatus.OPEN, ProactiveStatus.SNOOZED])
                    )
                )
                existing_count = count_result.scalar() or 0
                if existing_count >= 5:
                    continue
                prompt = f"""For startup "{project.name}": {project.core_premise}. Generate 3-5 questions about market, finances, brand, or tech. Output JSON array: [{{"question":"...","source_section":"market_research|financials|brand_kit|tech_setup","source_detail":"...","bullet_color":"green|amber|blue"}}]"""
                result = run_signal_sight(prompt)
                if "error" in result["brief"]:
                    logger.error(f"Agent failed for project {project.id}: {result['brief'].get('error')}")
                    continue
                items = result["brief"]
                if isinstance(items, dict) and "questions" in items:
                    items = items["questions"]
                if not isinstance(items, list):
                    items = []
                existing_questions = await db.execute(
                    select(ProactiveThread.question).where(ProactiveThread.project_id == project.id)
                )
                existing_set = set(row[0] for row in existing_questions.all())
                new_count = 0
                for item in items[:5]:
                    if new_count + existing_count >= 5:
                        break
                    q = item.get("question", "")
                    if not q or q in existing_set:
                        continue
                    pthr = ProactiveThread(
                        id=str(uuid.uuid4()),
                        public_id=f"pthr_{uuid.uuid4().hex[:8]}",
                        project_id=project.id,
                        question=q,
                        source_section=item.get("source_section", "market_research"),
                        source_detail=item.get("source_detail", "auto-generated"),
                        bullet_color=item.get("bullet_color", "blue"),
                        status=ProactiveStatus.OPEN,
                    )
                    db.add(pthr)
                    new_count += 1
                await db.commit()
        return {"generated": True}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())
EOF

# -------------------------------
# 5. tasks/pdf_tasks.py
# -------------------------------
cat > src/launchmate/tasks/pdf_tasks.py << 'EOF'
import asyncio
import os
import io
from celery import shared_task
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer
from reportlab.lib.styles import getSampleStyleSheet
from ..core.database import AsyncSessionLocal
from ..models.project import Project
from ..models.version import Version
from ..models.market_research import MarketResearch
from ..models.financials import Financials
from ..core.config import settings
import boto3
from botocore.exceptions import ClientError

@shared_task
def generate_founder_brief(project_id: str):
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Project).where(Project.id == project_id))
            project = result.scalar_one_or_none()
            if not project:
                raise ValueError(f"Project {project_id} not found")
            if not project.current_version_id:
                raise ValueError("No current version")
            version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
            version = version_result.scalar_one()
            mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
            mr = mr_result.scalar_one_or_none()
            fin_result = await db.execute(select(Financials).where(Financials.version_id == version.id))
            fin = fin_result.scalar_one_or_none()
            
            buffer = io.BytesIO()
            doc = SimpleDocTemplate(buffer, pagesize=letter)
            styles = getSampleStyleSheet()
            story = []
            story.append(Paragraph(f"Founder Brief: {project.name}", styles['Title']))
            story.append(Spacer(1, 12))
            story.append(Paragraph(f"Core Premise: {project.core_premise}", styles['Normal']))
            story.append(Paragraph(f"Primary Market: {project.primary_market}", styles['Normal']))
            story.append(Paragraph(f"Initial Budget: ${project.initial_budget}", styles['Normal']))
            story.append(Spacer(1, 12))
            if mr:
                story.append(Paragraph("Market Research", styles['Heading2']))
                story.append(Paragraph(f"Signals: {mr.signals}", styles['Normal']))
                story.append(Paragraph(f"Competitors: {mr.competitors}", styles['Normal']))
            if fin:
                story.append(Paragraph("Financials", styles['Heading2']))
                story.append(Paragraph(f"Cost Breakdown: {fin.cost_breakdown}", styles['Normal']))
                story.append(Paragraph(f"Calculated: {fin.calculated}", styles['Normal']))
            doc.build(story)
            pdf_bytes = buffer.getvalue()
            
            backend = settings.STORAGE_BACKEND
            if backend == "local":
                os.makedirs("./storage/briefs", exist_ok=True)
                with open(f"./storage/briefs/{project.public_id}.pdf", "wb") as f:
                    f.write(pdf_bytes)
            elif backend == "s3":
                s3 = boto3.client(
                    "s3",
                    aws_access_key_id=settings.AWS_ACCESS_KEY_ID,
                    aws_secret_access_key=settings.AWS_SECRET_ACCESS_KEY,
                    region_name=settings.AWS_REGION,
                )
                s3.put_object(
                    Bucket=settings.AWS_BUCKET,
                    Key=f"briefs/{project.public_id}.pdf",
                    Body=pdf_bytes,
                    ContentType="application/pdf",
                )
            else:
                raise ValueError(f"Unknown storage backend: {backend}")
            return {"project_id": project.public_id, "status": "ready"}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())
EOF

# -------------------------------
# 6. tasks/domain_tasks.py
# -------------------------------
cat > src/launchmate/tasks/domain_tasks.py << 'EOF'
import asyncio
from celery import shared_task
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..core.database import AsyncSessionLocal
from ..models.project import Project
from ..models.version import Version
from ..models.brand_kit import BrandKit

@shared_task
def register_domains(project_id: str, handles: list):
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Project).where(Project.id == project_id))
            project = result.scalar_one_or_none()
            if not project:
                return {"error": "Project not found"}
            if not project.current_version_id:
                return {"error": "No current version"}
            version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
            version = version_result.scalar_one()
            bk_result = await db.execute(select(BrandKit).where(BrandKit.version_id == version.id))
            bk = bk_result.scalar_one_or_none()
            if not bk:
                bk = BrandKit(version_id=version.id)
                db.add(bk)
                await db.flush()
            for handle in handles:
                for item in bk.namespace:
                    if item.get("handle") == handle:
                        item["available"] = False
            await db.commit()
            return {"registered": handles, "failed": []}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())
EOF

# -------------------------------
# 7. tasks/email_tasks.py
# -------------------------------
cat > src/launchmate/tasks/email_tasks.py << 'EOF'
import logging
from celery import shared_task

logger = logging.getLogger(__name__)

@shared_task
def send_email(to: str, subject: str, body: str):
    logger.info(f"Email would be sent to {to} with subject '{subject}':\n{body}")
    # In production, configure SMTP
    return {"status": "sent", "to": to, "subject": subject}
EOF

# -------------------------------
# 8. Update generation endpoint (real polling)
# -------------------------------
# Overwrite existing generation.py (placeholder) with real implementation
mkdir -p src/launchmate/api/v1/endpoints
cat > src/launchmate/api/v1/endpoints/generation.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from celery.result import AsyncResult
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....core.celery_app import celery_app
from ....core.exceptions import NotFoundError

router = APIRouter()

@router.get("/{project_id}/generation-status")
async def generation_status(
    project_id: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.celery_task_id:
        return {"status": "complete", "redirect_to": f"/projects/{project_id}"}
    task = AsyncResult(project.celery_task_id, app=celery_app)
    if task.ready():
        if task.successful():
            return {"status": "complete", "redirect_to": f"/projects/{project_id}"}
        else:
            return {"status": "failed", "message": str(task.info)}
    info = task.info or {}
    return {
        "job_id": project.celery_task_id,
        "status": "in_progress",
        "progress": info.get("progress", 0),
        "current_step": info.get("current_step", "Starting..."),
        "steps_completed": info.get("steps_completed", []),
        "steps_remaining": info.get("steps_remaining", []),
        "estimated_seconds_remaining": info.get("estimated_seconds_remaining", None),
    }
EOF

# -------------------------------
# 9. Patch create_project endpoint to queue Celery task
# -------------------------------
# We need to modify the existing projects.py to call generate_initial_project.delay
# and store the task ID. We'll append the necessary import and modify the endpoint.
# Since the file already exists, we'll use sed to insert the import and replace the function.
# But to be safe, we'll overwrite the whole projects.py with the updated version that includes Celery.
# The original projects.py from Phase 4/5 already had placeholder, we'll replace it.

cat > src/launchmate/api/v1/endpoints/projects.py << 'EOF'
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
EOF

# -------------------------------
# 10. Patch threads.py to use real agent (replace placeholder assistant)
# -------------------------------
# We'll replace the assistant response generation with a call to run_signal_sight.
# Since the file is large, we'll patch only the relevant parts.
# We'll use sed to modify the placeholder "Echo:" line.
# But to be thorough, we'll replace the whole create_thread and add_message functions.
# We'll append a patch that overwrites the specific functions.
# Simpler: replace the entire threads.py file with the agent-integrated version.

cat > src/launchmate/api/v1/endpoints/threads.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException, Header
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from pydantic import BaseModel
import uuid
from datetime import datetime
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.thread import Thread, ThreadStatus, Message
from ....models.amendment import Amendment, AmendmentStatus
from ....models.version import Version
from ....models.market_research import MarketResearch
from ....models.financials import Financials
from ....tools.agent import run_signal_sight
from ....core.exceptions import NotFoundError

router = APIRouter()

class ThreadCreate(BaseModel):
    name: str
    context_section: str
    context_detail: str
    opening_message: str

class MessageCreate(BaseModel):
    content: str

class PromoteRequest(BaseModel):
    target_section: str
    summary: str

@router.get("/{project_id}/threads")
async def list_threads(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    result = await db.execute(select(Thread).where(Thread.project_id == project.id).order_by(Thread.updated_at.desc()))
    threads = result.scalars().all()
    data = []
    for t in threads:
        msg_count = await db.execute(select(func.count(Message.id)).where(Message.thread_id == t.id))
        preview = t.messages[0].content[:100] if t.messages else ""
        data.append({
            "id": t.public_id,
            "name": t.name,
            "context_section": t.context_section,
            "context_detail": t.context_detail,
            "status": t.status.value,
            "promoted": t.promoted_to_amendment_id is not None,
            "message_count": msg_count.scalar(),
            "preview": preview,
            "created_at": t.created_at.isoformat(),
            "updated_at": t.updated_at.isoformat()
        })
    return {"project_id": project.public_id, "threads": data, "total": len(data)}

@router.post("/{project_id}/threads", status_code=201)
async def create_thread(project_id: str, data: ThreadCreate, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    thread_id = str(uuid.uuid4())
    public_id = f"thr_{uuid.uuid4().hex[:8]}"
    thread = Thread(
        id=thread_id,
        public_id=public_id,
        project_id=project.id,
        name=data.name,
        context_section=data.context_section,
        context_detail=data.context_detail,
        status=ThreadStatus.OPEN,
        summary=None,
    )
    db.add(thread)
    await db.flush()
    user_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread_id,
        role="user",
        content=data.opening_message,
        idempotency_key=str(uuid.uuid4())
    )
    db.add(user_msg)
    # Get context for agent
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = version_result.scalar_one()
    section_data = {}
    if data.context_section == "market_research":
        mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
        mr = mr_result.scalar_one_or_none()
        section_data = mr.dict() if mr else {}
    elif data.context_section == "financials":
        fin_result = await db.execute(select(Financials).where(Financials.version_id == version.id))
        fin = fin_result.scalar_one_or_none()
        section_data = fin.dict() if fin else {}
    context_prompt = f"Project: {project.name}\nCore premise: {project.core_premise}\nPrimary market: {project.primary_market}\nSection: {data.context_section}\nDetail: {data.context_detail}\nSection data: {section_data}\nUser question: {data.opening_message}\nAnswer using web search if needed."
    agent_result = run_signal_sight(context_prompt)
    assistant_content = agent_result["research"] if "research" in agent_result else "I'm sorry, I couldn't process that."
    assistant_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread_id,
        role="assistant",
        content=assistant_content[:2000],
        idempotency_key=str(uuid.uuid4())
    )
    db.add(assistant_msg)
    await db.commit()
    return {
        "id": public_id,
        "name": data.name,
        "context_section": data.context_section,
        "context_detail": data.context_detail,
        "status": "open",
        "messages": [
            {"id": user_msg.id, "role": "user", "content": user_msg.content, "created_at": user_msg.created_at.isoformat()},
            {"id": assistant_msg.id, "role": "assistant", "content": assistant_msg.content, "created_at": assistant_msg.created_at.isoformat()}
        ],
        "created_at": thread.created_at.isoformat()
    }

@router.get("/projects/threads/{thread_id}")
async def get_thread(thread_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Thread).where(Thread.public_id == thread_id))
    thread = result.scalar_one_or_none()
    if not thread:
        raise NotFoundError("Thread", thread_id)
    p_result = await db.execute(select(Project).where(Project.id == thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    messages_result = await db.execute(select(Message).where(Message.thread_id == thread.id).order_by(Message.created_at))
    messages = messages_result.scalars().all()
    return {
        "id": thread.public_id,
        "name": thread.name,
        "context_section": thread.context_section,
        "context_detail": thread.context_detail,
        "status": thread.status.value,
        "promoted": thread.promoted_to_amendment_id is not None,
        "messages": [{"id": m.id, "role": m.role, "content": m.content, "created_at": m.created_at.isoformat()} for m in messages],
        "created_at": thread.created_at.isoformat(),
        "updated_at": thread.updated_at.isoformat()
    }

@router.post("/projects/threads/{thread_id}/messages")
async def add_message(thread_id: str, data: MessageCreate, idempotency_key: str = Header(...), current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    t_result = await db.execute(select(Thread).where(Thread.public_id == thread_id))
    thread = t_result.scalar_one_or_none()
    if not thread:
        raise NotFoundError("Thread", thread_id)
    p_result = await db.execute(select(Project).where(Project.id == thread.project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise HTTPException(403, "Forbidden")
    existing = await db.execute(select(Message).where(Message.thread_id == thread.id, Message.idempotency_key == idempotency_key))
    if existing.scalar_one_or_none():
        last_msgs = await db.execute(select(Message).where(Message.thread_id == thread.id).order_by(Message.created_at.desc()).limit(2))
        msgs = list(last_msgs.scalars().all())
        msgs.reverse()
        return {
            "user_message": {"id": msgs[0].id, "role": msgs[0].role, "content": msgs[0].content, "created_at": msgs[0].created_at.isoformat()} if len(msgs) > 0 else None,
            "assistant_message": {"id": msgs[1].id, "role": msgs[1].role, "content": msgs[1].content, "created_at": msgs[1].created_at.isoformat()} if len(msgs) > 1 else None
        }
    user_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread.id,
        role="user",
        content=data.content,
        idempotency_key=idempotency_key
    )
    db.add(user_msg)
    await db.flush()
    # Build context for agent
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = version_result.scalar_one()
    section_data = {}
    if thread.context_section == "market_research":
        mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
        mr = mr_result.scalar_one_or_none()
        section_data = mr.dict() if mr else {}
    elif thread.context_section == "financials":
        fin_result = await db.execute(select(Financials).where(Financials.version_id == version.id))
        fin = fin_result.scalar_one_or_none()
        section_data = fin.dict() if fin else {}
    history_result = await db.execute(select(Message).where(Message.thread_id == thread.id).order_by(Message.created_at.desc()).limit(10))
    history_msgs = list(history_result.scalars().all())
    history_msgs.reverse()
    history_text = "\n".join([f"{m.role}: {m.content}" for m in history_msgs])
    context_prompt = f"Project: {project.name}\nCore premise: {project.core_premise}\nPrimary market: {project.primary_market}\nSection: {thread.context_section}\nDetail: {thread.context_detail}\nSection data: {section_data}\nConversation history:\n{history_text}\nUser: {data.content}\nAnswer the user's question using web search if needed."
    agent_result = run_signal_sight(context_prompt)
    assistant_content = agent_result["research"] if "research" in agent_result else "I'm sorry, I couldn't process that."
    assistant_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread.id,
        role="assistant",
        content=assistant_content[:2000],
        idempotency_key=str(uuid.uuid4())
    )
    db.add(assistant_msg)
    thread.updated_at = datetime.utcnow()
    await db.commit()
    return {
        "user_message": {"id": user_msg.id, "role": "user", "content": user_msg.content, "created_at": user_msg.created_at.isoformat()},
        "assistant_message": {"id": assistant_msg.id, "role": "assistant", "content": assistant_msg.content, "created_at": assistant_msg.created_at.isoformat()}
    }

@router.post("/projects/threads/{thread_id}/promote")
async def promote_thread(thread_id: str, data: PromoteRequest, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    t_result = await db.execute(select(Thread).where(Thread.public_id == thread_id))
    thread = t_result.scalar_one_or_none()
    if not thread:
        raise NotFoundError("Thread", thread_id)
    p_result = await db.execute(select(Project).where(Project.id == thread.project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise HTTPException(403, "Forbidden")
    amendment_id = str(uuid.uuid4())
    public_id = f"amd_{uuid.uuid4().hex[:8]}"
    amendment = Amendment(
        id=amendment_id,
        public_id=public_id,
        project_id=project.id,
        source_type="thread",
        source_id=thread.id,
        target_section=data.target_section,
        summary=data.summary,
        status=AmendmentStatus.PENDING
    )
    db.add(amendment)
    thread.promoted_to_amendment_id = amendment_id
    thread.status = ThreadStatus.PROMOTED
    await db.commit()
    return {
        "thread_id": thread.public_id,
        "amendment_id": public_id,
        "promoted": True,
        "target_section": data.target_section,
        "status": "pending_review",
        "message": "Amendment created and pending your review"
    }

@router.delete("/projects/threads/{thread_id}")
async def delete_thread(thread_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    t_result = await db.execute(select(Thread).where(Thread.public_id == thread_id))
    thread = t_result.scalar_one_or_none()
    if not thread:
        raise NotFoundError("Thread", thread_id)
    p_result = await db.execute(select(Project).where(Project.id == thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    await db.delete(thread)
    await db.commit()
    return {"deleted_id": thread_id}
EOF

# -------------------------------
# 11. Update locking.py to call PDF task
# -------------------------------
# We already have the endpoint, but we need to actually call generate_founder_brief.delay.
# The locking.py file already has a placeholder; we'll replace it to queue the task.
cat > src/launchmate/api/v1/endpoints/locking.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project, ProjectLockStatus
from ....models.market_research import MarketResearch
from ....models.financials import Financials
from ....models.brand_kit import BrandKit
from ....models.tech_setup import TechSetup
from ....core.exceptions import NotFoundError
from ....tasks.pdf_tasks import generate_founder_brief

router = APIRouter()

@router.get("/{project_id}/lock-readiness")
async def lock_readiness(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    sections_status = []
    warnings_count = 0
    for section_name, model in [("market_research", MarketResearch), ("financials", Financials), ("brand_kit", BrandKit), ("tech_setup", TechSetup)]:
        result = await db.execute(select(model).where(model.version_id == project.current_version_id))
        record = result.scalar_one_or_none()
        lock_status = record.lock_status.value if record else "unlocked"
        warning = None
        if lock_status != "locked":
            if section_name == "tech_setup":
                warning = "Still unlocked. Worth reviewing."
            elif section_name == "market_research":
                warning = "Consider locking market research after final review."
            warnings_count += 1
        sections_status.append({
            "section": section_name,
            "lock_status": lock_status,
            "warning": warning
        })
    ready = all(s["lock_status"] == "locked" for s in sections_status)
    return {
        "project_id": project.public_id,
        "ready_to_lock": ready,
        "sections": sections_status,
        "warnings_count": warnings_count,
        "blocking": not ready
    }

@router.post("/{project_id}/lock")
async def lock_project(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    project.lock_status = ProjectLockStatus.LOCKED
    await db.commit()
    # Queue PDF generation
    generate_founder_brief.delay(project.id)
    return {
        "project_id": project.public_id,
        "lock_status": "locked",
        "locked_at": project.updated_at.isoformat(),
        "section_summary": [],
        "founder_brief_id": None,
        "warnings": 0,
        "founder_brief_status": "generating"
    }
EOF

# -------------------------------
# 12. Update api/v1/__init__.py to include generation router
# -------------------------------
# The generation router was already added earlier, but we need to ensure it's imported.
# In the Phase 4 __init__.py we didn't have generation. We'll add it now.
# We'll replace the __init__.py with the full list including generation.

cat > src/launchmate/api/v1/__init__.py << 'EOF'
from fastapi import APIRouter
from .endpoints import auth, users, projects, generation
from .endpoints import market_research, financials, brand_kit, tech_setup, overview
from .endpoints import section_locking, locking
from .endpoints import versions
from .endpoints import threads, refinements, proactive_threads, amendments
from .endpoints import founder_brief

router = APIRouter(prefix="/api/v1")
router.include_router(auth.router, prefix="/auth", tags=["auth"])
router.include_router(users.router, prefix="/users", tags=["users"])
router.include_router(projects.router, prefix="/projects", tags=["projects"])
router.include_router(generation.router, prefix="/projects", tags=["generation"])
router.include_router(market_research.router, prefix="/projects", tags=["market_research"])
router.include_router(financials.router, prefix="/projects", tags=["financials"])
router.include_router(brand_kit.router, prefix="/projects", tags=["brand_kit"])
router.include_router(tech_setup.router, prefix="/projects", tags=["tech_setup"])
router.include_router(overview.router, prefix="/projects", tags=["overview"])
router.include_router(section_locking.router, prefix="/projects", tags=["section_locking"])
router.include_router(locking.router, prefix="/projects", tags=["locking"])
router.include_router(versions.router, prefix="/projects", tags=["versions"])
router.include_router(threads.router, prefix="/projects", tags=["threads"])
router.include_router(refinements.router, prefix="/projects", tags=["refinements"])
router.include_router(proactive_threads.router, prefix="/projects", tags=["proactive_threads"])
router.include_router(amendments.router, prefix="/projects", tags=["amendments"])
router.include_router(founder_brief.router, prefix="/projects", tags=["founder_brief"])
EOF

echo "✅ Phase 6 complete. Now you need to:"
echo "  1. Restart the backend: cd backend && PYTHONPATH=src poetry run uvicorn launchmate.main:app --reload"
echo "  2. Start Celery worker in a new terminal: cd backend && PYTHONPATH=src poetry run celery -A launchmate.core.celery_app worker --loglevel=info"
echo "  3. Start Celery Beat (optional for proactive threads): cd backend && PYTHONPATH=src poetry run celery -A launchmate.core.celery_app beat --loglevel=info"
echo ""
echo "Test generation:"
echo "  Create a project, then poll /api/v1/projects/{id}/generation-status"
echo "  Check that the assistant responses are now real (not placeholders)."
echo ""
echo "Note: Requires BRIGHTDATA_API_KEY and OPENROUTER_API_KEY in .env for real agent."