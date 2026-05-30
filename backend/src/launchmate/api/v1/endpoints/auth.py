from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel, EmailStr
import uuid
from ....core.database import get_db
from ....core.security import get_password_hash, verify_password, create_access_token
from ....models.user import User, UserRole
from ....api.dependencies import get_current_user

router = APIRouter()

class RegisterRequest(BaseModel):
    name: str
    email: EmailStr
    password: str

class LoginRequest(BaseModel):
    email: EmailStr
    password: str

def generate_avatar_initials(name: str) -> str:
    parts = name.strip().split()
    if len(parts) == 1:
        return parts[0][:2].upper()
    return (parts[0][0] + parts[-1][0]).upper()

@router.post("/register", status_code=201)
async def register(data: RegisterRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == data.email))
    if result.scalar_one_or_none():
        raise HTTPException(400, "Email already registered")
    
    user_id = str(uuid.uuid4())
    public_id = f"usr_{uuid.uuid4().hex[:8]}"
    avatar_initials = generate_avatar_initials(data.name)
    hashed = get_password_hash(data.password)
    
    user = User(
        id=user_id,
        public_id=public_id,
        name=data.name,
        email=data.email,
        hashed_password=hashed,
        role=UserRole.BUILDER,
        avatar_initials=avatar_initials,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    
    token = create_access_token(data={"sub": user.id})
    return {
        "user": {
            "id": user.public_id,
            "name": user.name,
            "email": user.email,
            "role": user.role.value,
            "avatar_initials": user.avatar_initials,
            "created_at": user.created_at.isoformat(),
        },
        "token": token
    }

@router.post("/login")
async def login(data: LoginRequest, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.email == data.email))
    user = result.scalar_one_or_none()
    if not user or not verify_password(data.password, user.hashed_password):
        raise HTTPException(401, "Invalid credentials")
    
    token = create_access_token(data={"sub": user.id})
    return {
        "user": {
            "id": user.public_id,
            "name": user.name,
            "email": user.email,
            "role": user.role.value,
            "avatar_initials": user.avatar_initials,
            "created_at": user.created_at.isoformat(),
        },
        "token": token
    }

@router.post("/logout")
async def logout():
    return {"message": "Logged out"}

@router.post("/refresh")
async def refresh(current_user: User = Depends(get_current_user)):
    new_token = create_access_token(data={"sub": current_user.id})
    return {"token": new_token}
