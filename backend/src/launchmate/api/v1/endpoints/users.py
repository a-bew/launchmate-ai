from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from pydantic import BaseModel
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User, UserRole

router = APIRouter()

class UpdateProfileRequest(BaseModel):
    name: str | None = None
    role: str | None = None

def generate_avatar_initials(name: str) -> str:
    parts = name.strip().split()
    if len(parts) == 1:
        return parts[0][:2].upper()
    return (parts[0][0] + parts[-1][0]).upper()

@router.get("/me")
async def get_me(current_user: User = Depends(get_current_user)):
    return {
        "id": current_user.public_id,
        "name": current_user.name,
        "email": current_user.email,
        "role": current_user.role.value,
        "avatar_initials": current_user.avatar_initials,
        "created_at": current_user.created_at.isoformat(),
    }

@router.patch("/me")
async def update_me(
    data: UpdateProfileRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    if data.name:
        current_user.name = data.name
        current_user.avatar_initials = generate_avatar_initials(data.name)
    if data.role:
        try:
            current_user.role = UserRole(data.role)
        except ValueError:
            raise HTTPException(400, "Invalid role")
    await db.commit()
    await db.refresh(current_user)
    return {
        "id": current_user.public_id,
        "name": current_user.name,
        "email": current_user.email,
        "role": current_user.role.value,
        "avatar_initials": current_user.avatar_initials,
        "created_at": current_user.created_at.isoformat(),
    }
