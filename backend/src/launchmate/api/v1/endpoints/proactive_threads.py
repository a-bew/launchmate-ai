from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from datetime import datetime, timedelta
import uuid
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.proactive_thread import ProactiveThread, ProactiveStatus
from ....core.exceptions import NotFoundError

router = APIRouter()

class SnoozeRequest(BaseModel):
    snooze_hours: int

@router.get("/{project_id}/proactive-threads")
async def list_proactive_threads(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    result = await db.execute(select(ProactiveThread).where(ProactiveThread.project_id == project.id, ProactiveThread.status.in_([ProactiveStatus.OPEN, ProactiveStatus.SNOOZED])).order_by(ProactiveThread.created_at.desc()))
    threads = result.scalars().all()
    data = []
    for t in threads:
        data.append({
            "id": t.public_id,
            "question": t.question,
            "source_section": t.source_section,
            "source_detail": t.source_detail,
            "bullet_color": t.bullet_color,
            "status": t.status.value,
            "created_at": t.created_at.isoformat()
        })
    return {"project_id": project.public_id, "threads": data, "total": len(data)}

@router.post("/proactive-threads/{pthr_id}/explore", status_code=201)
async def explore_proactive_thread(pthr_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(ProactiveThread).where(ProactiveThread.public_id == pthr_id))
    p_thread = r_result.scalar_one_or_none()
    if not p_thread:
        raise NotFoundError("Proactive thread", pthr_id)
    p_result = await db.execute(select(Project).where(Project.id == p_thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    # Convert to ideation thread (simplified)
    from ....models.thread import Thread, ThreadStatus
    thread_id = str(uuid.uuid4())
    public_id = f"thr_{uuid.uuid4().hex[:8]}"
    new_thread = Thread(
        id=thread_id,
        public_id=public_id,
        project_id=p_thread.project_id,
        name=p_thread.question[:50],
        context_section=p_thread.source_section,
        context_detail=p_thread.source_detail,
        status=ThreadStatus.OPEN,
    )
    db.add(new_thread)
    p_thread.status = ProactiveStatus.DISMISSED
    await db.commit()
    return {
        "ideation_thread_id": public_id,
        "name": p_thread.question[:50],
        "context_section": p_thread.source_section,
        "context_detail": p_thread.source_detail,
        "opening_message": p_thread.question,
        "redirect_to": f"/projects/{p_thread.project_id}/threads/{public_id}"
    }

@router.post("/proactive-threads/{pthr_id}/dismiss")
async def dismiss_proactive_thread(pthr_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(ProactiveThread).where(ProactiveThread.public_id == pthr_id))
    p_thread = r_result.scalar_one_or_none()
    if not p_thread:
        raise NotFoundError("Proactive thread", pthr_id)
    p_result = await db.execute(select(Project).where(Project.id == p_thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    p_thread.status = ProactiveStatus.DISMISSED
    await db.commit()
    return {"id": pthr_id, "status": "dismissed"}

@router.post("/proactive-threads/{pthr_id}/snooze")
async def snooze_proactive_thread(pthr_id: str, data: SnoozeRequest, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(ProactiveThread).where(ProactiveThread.public_id == pthr_id))
    p_thread = r_result.scalar_one_or_none()
    if not p_thread:
        raise NotFoundError("Proactive thread", pthr_id)
    p_result = await db.execute(select(Project).where(Project.id == p_thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    p_thread.status = ProactiveStatus.SNOOZED
    p_thread.snooze_until = datetime.utcnow() + timedelta(hours=data.snooze_hours)
    await db.commit()
    return {"id": pthr_id, "status": "snoozed", "snooze_until": p_thread.snooze_until.isoformat()}
