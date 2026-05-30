from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import Optional
import uuid
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.refinement import Refinement, RefinementStatus
from ....core.exceptions import NotFoundError

router = APIRouter()

class RefineRequest(BaseModel):
    target_element: str
    target_id: Optional[str] = None
    instruction: str

class RefinementModify(BaseModel):
    modified_after: str

@router.post("/{project_id}/sections/{section}/refine")
async def create_refinement(
    project_id: str,
    section: str,
    data: RefineRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    refinement_id = str(uuid.uuid4())
    public_id = f"ref_{uuid.uuid4().hex[:8]}"
    refinement = Refinement(
        id=refinement_id,
        public_id=public_id,
        project_id=project.id,
        target_section=section,
        target_element=data.target_element,
        target_id=data.target_id,
        instruction=data.instruction,
        diff_before="Original content placeholder",
        diff_after="Modified content placeholder",
        ripple_preview={"affected_sections": ["overview"]},
        status=RefinementStatus.PENDING
    )
    db.add(refinement)
    await db.commit()
    return {
        "refinement_id": public_id,
        "target_section": section,
        "target_element": data.target_element,
        "target_id": data.target_id,
        "diff": {
            "before": refinement.diff_before,
            "after": refinement.diff_after
        },
        "ripple_preview": refinement.ripple_preview,
        "status": "pending_review"
    }

@router.post("/refinements/{refinement_id}/accept")
async def accept_refinement(refinement_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(Refinement).where(Refinement.public_id == refinement_id))
    refinement = r_result.scalar_one_or_none()
    if not refinement:
        raise NotFoundError("Refinement", refinement_id)
    p_result = await db.execute(select(Project).where(Project.id == refinement.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    refinement.status = RefinementStatus.ACCEPTED
    await db.commit()
    return {
        "refinement_id": refinement.public_id,
        "status": "accepted",
        "sections_updated": [refinement.target_section],
        "new_version_id": "ver_placeholder",
        "message": "Refinement accepted. Version created."
    }

@router.post("/refinements/{refinement_id}/reject")
async def reject_refinement(refinement_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(Refinement).where(Refinement.public_id == refinement_id))
    refinement = r_result.scalar_one_or_none()
    if not refinement:
        raise NotFoundError("Refinement", refinement_id)
    p_result = await db.execute(select(Project).where(Project.id == refinement.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    refinement.status = RefinementStatus.REJECTED
    await db.commit()
    return {"refinement_id": refinement.public_id, "status": "rejected"}

@router.patch("/refinements/{refinement_id}")
async def modify_refinement(refinement_id: str, data: RefinementModify, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(Refinement).where(Refinement.public_id == refinement_id))
    refinement = r_result.scalar_one_or_none()
    if not refinement:
        raise NotFoundError("Refinement", refinement_id)
    p_result = await db.execute(select(Project).where(Project.id == refinement.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    refinement.diff_after = data.modified_after
    await db.commit()
    return {
        "refinement_id": refinement.public_id,
        "diff": {
            "before": refinement.diff_before,
            "after": refinement.diff_after
        },
        "status": "pending_review"
    }
