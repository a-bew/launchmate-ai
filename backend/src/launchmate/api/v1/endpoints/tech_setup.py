from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.tech_setup import TechSetup, SectionLockStatus
from ....core.exceptions import NotFoundError

router = APIRouter()

async def get_current_version_tech_setup(project_id: str, user_id: str, db: AsyncSession):
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
    ts_result = await db.execute(select(TechSetup).where(TechSetup.version_id == version.id))
    tech_setup = ts_result.scalar_one_or_none()
    if not tech_setup:
        tech_setup = TechSetup(version_id=version.id, online_presence={}, automations={}, store={})
        db.add(tech_setup)
        await db.commit()
        await db.refresh(tech_setup)
    return tech_setup, project

@router.get("/{project_id}/tech-setup")
async def get_tech_setup(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    ts, project = await get_current_version_tech_setup(project_id, current_user.id, db)
    return {
        "project_id": project.public_id,
        "version_id": ts.version_id,
        "lock_status": ts.lock_status.value,
        "online_presence": ts.online_presence,
        "automations": ts.automations,
        "store": ts.store,
        "updated_at": ts.updated_at.isoformat()
    }
