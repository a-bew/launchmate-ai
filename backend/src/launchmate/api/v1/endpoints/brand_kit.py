from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import List
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.brand_kit import BrandKit, SectionLockStatus
from ....core.exceptions import NotFoundError, LockedSectionError

router = APIRouter()

class LogoSelect(BaseModel):
    selected_logo_id: str

class NamespaceCheckRequest(BaseModel):
    handles: List[str]

class NamespaceCheckResponse(BaseModel):
    results: dict

async def get_current_version_brand_kit(project_id: str, user_id: str, db: AsyncSession):
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
    bk_result = await db.execute(select(BrandKit).where(BrandKit.version_id == version.id))
    brand_kit = bk_result.scalar_one_or_none()
    if not brand_kit:
        brand_kit = BrandKit(version_id=version.id, namespace=[], typography={}, logo_options=[], selected_logo_id=None)
        db.add(brand_kit)
        await db.commit()
        await db.refresh(brand_kit)
    return brand_kit, project

@router.get("/{project_id}/brand-kit")
async def get_brand_kit(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    bk, project = await get_current_version_brand_kit(project_id, current_user.id, db)
    return {
        "project_id": project.public_id,
        "version_id": bk.version_id,
        "lock_status": bk.lock_status.value,
        "namespace": bk.namespace,
        "typography": bk.typography,
        "logo_options": bk.logo_options,
        "updated_at": bk.updated_at.isoformat()
    }

@router.patch("/{project_id}/brand-kit/logo")
async def select_logo(
    project_id: str,
    data: LogoSelect,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    bk, project = await get_current_version_brand_kit(project_id, current_user.id, db)
    if bk.lock_status == SectionLockStatus.LOCKED:
        raise LockedSectionError("brand_kit")
    bk.selected_logo_id = data.selected_logo_id
    await db.commit()
    return {
        "selected_logo_id": data.selected_logo_id,
        "updated_at": bk.updated_at.isoformat()
    }

@router.post("/{project_id}/brand-kit/register-domains")
async def register_domains(
    project_id: str,
    data: NamespaceCheckRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    bk, project = await get_current_version_brand_kit(project_id, current_user.id, db)
    registered = []
    failed = []
    for handle in data.handles:
        # Simulate registration: mark as unavailable
        if handle.endswith((".app", ".com")):
            registered.append(handle)
            for item in bk.namespace:
                if item.get("handle") == handle:
                    item["available"] = False
        else:
            failed.append(handle)
    await db.commit()
    return {
        "registered": registered,
        "failed": failed,
        "message": "Domains queued for registration"
    }

@router.post("/{project_id}/brand-kit/check-namespace", response_model=NamespaceCheckResponse)
async def check_namespace(
    project_id: str,
    data: NamespaceCheckRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    # Mock check: .app and .com available
    results = {handle: handle.endswith((".app", ".com")) for handle in data.handles}
    return {"results": results}
