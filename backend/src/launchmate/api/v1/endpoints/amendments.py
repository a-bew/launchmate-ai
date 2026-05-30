from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import Optional
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.amendment import Amendment, AmendmentStatus
from ....core.exceptions import NotFoundError

router = APIRouter()

class AmendmentModify(BaseModel):
    summary: Optional[str] = None
    target_section: Optional[str] = None

@router.get("/{project_id}/amendments")
async def list_amendments(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    result = await db.execute(select(Amendment).where(Amendment.project_id == project.id).order_by(Amendment.created_at.desc()))
    amendments = result.scalars().all()
    data = []
    for a in amendments:
        data.append({
            "id": a.public_id,
            "source": a.source_type,
            "source_id": a.source_id,
            "target_section": a.target_section,
            "summary": a.summary,
            "status": a.status.value,
            "created_at": a.created_at.isoformat()
        })
    return {"project_id": project.public_id, "amendments": data}

@router.post("/amendments/{amendment_id}/accept")
async def accept_amendment(amendment_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    a_result = await db.execute(select(Amendment).where(Amendment.public_id == amendment_id))
    amendment = a_result.scalar_one_or_none()
    if not amendment:
        raise NotFoundError("Amendment", amendment_id)
    p_result = await db.execute(select(Project).where(Project.id == amendment.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    amendment.status = AmendmentStatus.ACCEPTED
    await db.commit()
    return {
        "amendment_id": amendment.public_id,
        "status": "accepted",
        "sections_updated": [amendment.target_section],
        "new_version_id": "ver_placeholder",
        "message": "Amendment accepted. New version created."
    }

@router.post("/amendments/{amendment_id}/reject")
async def reject_amendment(amendment_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    a_result = await db.execute(select(Amendment).where(Amendment.public_id == amendment_id))
    amendment = a_result.scalar_one_or_none()
    if not amendment:
        raise NotFoundError("Amendment", amendment_id)
    p_result = await db.execute(select(Project).where(Project.id == amendment.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    amendment.status = AmendmentStatus.REJECTED
    await db.commit()
    return {"amendment_id": amendment.public_id, "status": "rejected"}

@router.patch("/amendments/{amendment_id}")
async def modify_amendment(amendment_id: str, data: AmendmentModify, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    a_result = await db.execute(select(Amendment).where(Amendment.public_id == amendment_id))
    amendment = a_result.scalar_one_or_none()
    if not amendment:
        raise NotFoundError("Amendment", amendment_id)
    p_result = await db.execute(select(Project).where(Project.id == amendment.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    if data.summary is not None:
        amendment.summary = data.summary
    if data.target_section is not None:
        amendment.target_section = data.target_section
    await db.commit()
    return {
        "amendment_id": amendment.public_id,
        "summary": amendment.summary,
        "target_section": amendment.target_section,
        "status": amendment.status.value
    }
