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
