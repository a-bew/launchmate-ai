from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import Dict, Optional
import uuid
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version, VersionType
from ....models.market_research import MarketResearch
from ....models.financials import Financials
from ....models.brand_kit import BrandKit
from ....models.tech_setup import TechSetup
from ....core.exceptions import NotFoundError

router = APIRouter()

class BranchRequest(BaseModel):
    label: str

class MergeRequest(BaseModel):
    label: str
    sections: Dict[str, str]  # section -> version_id or branch_id

async def get_project(project_id: str, user_id: str, db: AsyncSession):
    result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    return project

@router.get("/{project_id}/versions")
async def list_versions(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    result = await db.execute(select(Version).where(Version.project_id == project.id).order_by(Version.created_at.desc()))
    versions = result.scalars().all()
    data = []
    for v in versions:
        data.append({
            "id": v.public_id,
            "label": v.label,
            "type": v.type.value,
            "number": v.number,
            "is_current": v.id == project.current_version_id,
            "parent_version_id": v.parent_version_id,
            "branch_id": v.branch_id,
            "changes": v.changes,
            "change_tags": [],
            "created_at": v.created_at.isoformat()
        })
    return {
        "project_id": project.public_id,
        "current_version_id": project.current_version_id,
        "versions": data
    }

@router.post("/{project_id}/versions/{version_id}/restore")
async def restore_version(project_id: str, version_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    v_result = await db.execute(select(Version).where(Version.public_id == version_id, Version.project_id == project.id))
    old_version = v_result.scalar_one_or_none()
    if not old_version:
        raise NotFoundError("Version", version_id)
    new_version_id = str(uuid.uuid4())
    new_public_id = f"ver_{uuid.uuid4().hex[:8]}"
    max_num_result = await db.execute(select(Version.number).where(Version.project_id == project.id, Version.type == VersionType.VERSION).order_by(Version.number.desc()).limit(1))
    max_num = max_num_result.scalar() or 0
    new_number = max_num + 1
    new_version = Version(
        id=new_version_id,
        public_id=new_public_id,
        project_id=project.id,
        parent_version_id=old_version.id,
        label=f"Restored from {old_version.label}",
        type=VersionType.VERSION,
        number=new_number,
        changes={"restored_from": old_version.public_id}
    )
    db.add(new_version)
    # Clone section data
    for model in [MarketResearch, Financials, BrandKit, TechSetup]:
        old_rec_result = await db.execute(select(model).where(model.version_id == old_version.id))
        old_rec = old_rec_result.scalar_one_or_none()
        if old_rec:
            new_rec = model(version_id=new_version_id)
            for col in model.__table__.columns:
                if col.name not in ["id", "version_id", "updated_at"]:
                    setattr(new_rec, col.name, getattr(old_rec, col.name))
            db.add(new_rec)
    project.current_version_id = new_version_id
    await db.commit()
    return {
        "project_id": project.public_id,
        "restored_from_version_id": old_version.public_id,
        "new_version_id": new_public_id,
        "message": f"Restored from {old_version.label}. New version created."
    }

@router.post("/{project_id}/versions/{version_id}/branch")
async def create_branch(project_id: str, version_id: str, data: BranchRequest, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    v_result = await db.execute(select(Version).where(Version.public_id == version_id, Version.project_id == project.id))
    base_version = v_result.scalar_one_or_none()
    if not base_version:
        raise NotFoundError("Version", version_id)
    branch_id = f"br_{uuid.uuid4().hex[:8]}"
    new_version = Version(
        id=str(uuid.uuid4()),
        public_id=branch_id,
        project_id=project.id,
        parent_version_id=base_version.id,
        label=data.label,
        type=VersionType.BRANCH,
        number=None,
        branch_id=branch_id,
        changes={}
    )
    db.add(new_version)
    for model in [MarketResearch, Financials, BrandKit, TechSetup]:
        old_rec_result = await db.execute(select(model).where(model.version_id == base_version.id))
        old_rec = old_rec_result.scalar_one_or_none()
        if old_rec:
            new_rec = model(version_id=new_version.id)
            for col in model.__table__.columns:
                if col.name not in ["id", "version_id", "updated_at"]:
                    setattr(new_rec, col.name, getattr(old_rec, col.name))
            db.add(new_rec)
    await db.commit()
    return {
        "branch_id": branch_id,
        "label": data.label,
        "parent_version_id": base_version.public_id,
        "created_at": new_version.created_at.isoformat()
    }

@router.post("/{project_id}/versions/merge")
async def merge_versions(project_id: str, data: MergeRequest, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    new_version_id = str(uuid.uuid4())
    new_public_id = f"ver_{uuid.uuid4().hex[:8]}"
    max_num_result = await db.execute(select(Version.number).where(Version.project_id == project.id, Version.type == VersionType.VERSION).order_by(Version.number.desc()).limit(1))
    max_num = max_num_result.scalar() or 0
    new_version = Version(
        id=new_version_id,
        public_id=new_public_id,
        project_id=project.id,
        label=data.label,
        type=VersionType.VERSION,
        number=max_num + 1,
        changes={"merged_from": data.sections}
    )
    db.add(new_version)
    sources = {}
    for source_public_id in set(data.sections.values()):
        src_result = await db.execute(select(Version).where(Version.public_id == source_public_id, Version.project_id == project.id))
        src = src_result.scalar_one_or_none()
        if src:
            sources[source_public_id] = src.id
    for section, source_public_id in data.sections.items():
        source_version_id = sources.get(source_public_id)
        if not source_version_id:
            continue
        model_map = {
            "market_research": MarketResearch,
            "financials": Financials,
            "brand_kit": BrandKit,
            "tech_setup": TechSetup
        }
        model = model_map.get(section)
        if not model:
            continue
        old_rec_result = await db.execute(select(model).where(model.version_id == source_version_id))
        old_rec = old_rec_result.scalar_one_or_none()
        if old_rec:
            new_rec = model(version_id=new_version.id)
            for col in model.__table__.columns:
                if col.name not in ["id", "version_id", "updated_at"]:
                    setattr(new_rec, col.name, getattr(old_rec, col.name))
            db.add(new_rec)
    project.current_version_id = new_version_id
    await db.commit()
    return {
        "new_version_id": new_public_id,
        "label": data.label,
        "merged_from": data.sections,
        "created_at": new_version.created_at.isoformat()
    }

@router.get("/{project_id}/versions/compare")
async def compare_versions(project_id: str, version_a: str = Query(...), version_b: str = Query(...), current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    v1_result = await db.execute(select(Version).where(Version.public_id == version_a, Version.project_id == project.id))
    v1 = v1_result.scalar_one_or_none()
    v2_result = await db.execute(select(Version).where(Version.public_id == version_b, Version.project_id == project.id))
    v2 = v2_result.scalar_one_or_none()
    if not v1 or not v2:
        raise HTTPException(404, "One or both versions not found")
    fin1 = await db.execute(select(Financials).where(Financials.version_id == v1.id))
    fin1_rec = fin1.scalar_one_or_none()
    fin2 = await db.execute(select(Financials).where(Financials.version_id == v2.id))
    fin2_rec = fin2.scalar_one_or_none()
    diff = {}
    if fin1_rec and fin2_rec:
        diff["financials"] = {
            "version_a": fin1_rec.calculated,
            "version_b": fin2_rec.calculated
        }
    return {
        "version_a": {"id": v1.public_id, "label": v1.label, "badge_color": "blue"},
        "version_b": {"id": v2.public_id, "label": v2.label, "badge_color": "pink"},
        "diff": diff
    }
