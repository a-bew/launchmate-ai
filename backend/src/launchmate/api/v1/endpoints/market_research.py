from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.market_research import MarketResearch, SectionLockStatus
from ....core.exceptions import NotFoundError, LockedSectionError

router = APIRouter()

async def get_current_version_market_research(project_id: str, user_id: str, db: AsyncSession):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    v_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = v_result.scalar_one_or_none()
    if not version:
        raise HTTPException(404, "Version not found")
    mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
    market_research = mr_result.scalar_one_or_none()
    if not market_research:
        market_research = MarketResearch(version_id=version.id, signals=[], competitors=[])
        db.add(market_research)
        await db.commit()
        await db.refresh(market_research)
    return market_research, project

@router.get("/{project_id}/market-research")
async def get_market_research(
    project_id: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    mr, project = await get_current_version_market_research(project_id, current_user.id, db)
    return {
        "project_id": project.public_id,
        "version_id": mr.version_id,
        "lock_status": mr.lock_status.value,
        "signals": mr.signals,
        "competitors": mr.competitors,
        "updated_at": mr.updated_at.isoformat()
    }
