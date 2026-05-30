from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.market_research import MarketResearch
from ....models.financials import Financials
from ....models.thread import Thread
from ....core.exceptions import NotFoundError

router = APIRouter()

@router.get("/{project_id}/overview")
async def get_overview(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        return {"error": "No current version"}
    v_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = v_result.scalar_one_or_none()
    if not version:
        return {"error": "Version not found"}
    mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
    mr = mr_result.scalar_one_or_none()
    mr_status = "done" if mr and (mr.signals or mr.competitors) else "pending"
    fin_result = await db.execute(select(Financials).where(Financials.version_id == version.id))
    fin = fin_result.scalar_one_or_none()
    fin_status = "done" if fin and fin.cost_breakdown else "pending"
    thread_count = await db.execute(select(func.count(Thread.id)).where(Thread.project_id == project.id, Thread.status == "open"))
    open_threads = thread_count.scalar() or 0
    return {
        "project_id": project.public_id,
        "name": project.name,
        "status": project.status.value,
        "lock_status": project.lock_status.value,
        "completion": 0,
        "sections": {
            "market_research": {"status": mr_status, "lock_status": mr.lock_status.value if mr else "unlocked"},
            "financials": {"status": fin_status, "lock_status": fin.lock_status.value if fin else "unlocked"},
            "brand_kit": {"status": "pending", "lock_status": "unlocked"},
            "tech_setup": {"status": "pending", "lock_status": "unlocked"},
        },
        "open_threads_count": open_threads,
        "updated_at": project.updated_at.isoformat(),
    }
