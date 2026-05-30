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
