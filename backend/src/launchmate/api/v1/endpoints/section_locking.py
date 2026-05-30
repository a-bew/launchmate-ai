from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.market_research import MarketResearch, SectionLockStatus
from ....models.financials import Financials
from ....models.brand_kit import BrandKit
from ....models.tech_setup import TechSetup
from ....core.exceptions import NotFoundError

router = APIRouter()

SECTION_MODELS = {
    "market_research": MarketResearch,
    "financials": Financials,
    "brand_kit": BrandKit,
    "tech_setup": TechSetup,
}

async def get_section_record(project_id: str, section: str, user_id: str, db: AsyncSession):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    model = SECTION_MODELS.get(section)
    if not model:
        raise HTTPException(400, f"Invalid section: {section}")
    result = await db.execute(select(model).where(model.version_id == project.current_version_id))
    record = result.scalar_one_or_none()
    if not record:
        record = model(version_id=project.current_version_id)
        db.add(record)
        await db.commit()
        await db.refresh(record)
    return record, project

@router.post("/{project_id}/sections/{section}/lock")
async def lock_section(
    project_id: str,
    section: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    record, project = await get_section_record(project_id, section, current_user.id, db)
    if record.lock_status == SectionLockStatus.LOCKED:
        raise HTTPException(400, "Section already locked")
    record.lock_status = SectionLockStatus.LOCKED
    await db.commit()
    await db.refresh(record)  # <-- Refresh the instance to load updated_at
    return {
        "project_id": project.public_id,
        "section": section,
        "lock_status": "locked",
        "locked_at": record.updated_at.isoformat(),
        "ai_mode_change": "AI will now optimize within this section rather than challenge it"
    }

@router.post("/{project_id}/sections/{section}/unlock")
async def unlock_section(
    project_id: str,
    section: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    record, project = await get_section_record(project_id, section, current_user.id, db)
    if record.lock_status == SectionLockStatus.UNLOCKED:
        raise HTTPException(400, "Section already unlocked")
    record.lock_status = SectionLockStatus.UNLOCKED
    await db.commit()
    await db.refresh(record)  # <-- Refresh the instance
    return {
        "project_id": project.public_id,
        "section": section,
        "lock_status": "unlocked",
        "unlocked_at": record.updated_at.isoformat(),
        "ai_mode_change": "AI will now challenge assumptions in this section again"
    }



