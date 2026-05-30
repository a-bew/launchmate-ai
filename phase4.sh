#!/bin/bash
set -e

echo "🚀 Phase 4: Auth + Users + Projects CRUD"

cd backend

# -------------------------------
# api/dependencies.py
# -------------------------------
mkdir -p src/launchmate/api
cat > src/launchmate/api/dependencies.py << 'EOF'
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession
from jose import JWTError
from ..core.database import get_db
from ..core.security import decode_access_token
from ..models.user import User

security = HTTPBearer()

async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: AsyncSession = Depends(get_db)
) -> User:
    token = credentials.credentials
    try:
        payload = decode_access_token(token)
        user_id: str = payload.get("sub")
        if user_id is None:
            raise HTTPException(status_code=401, detail="Invalid token")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
    
    from sqlalchemy import select
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=401, detail="User not found")
    return user
EOF

# -------------------------------
# api/v1/__init__.py
# -------------------------------
mkdir -p src/launchmate/api/v1/endpoints
cat > src/launchmate/api/v1/__init__.py << 'EOF'
from fastapi import APIRouter
from .endpoints import auth, users, projects

router = APIRouter(prefix="/api/v1")
router.include_router(auth.router, prefix="/auth", tags=["auth"])
router.include_router(users.router, prefix="/users", tags=["users"])
router.include_router(projects.router, prefix="/projects", tags=["projects"])
EOF

# -------------------------------
# api/v1/endpoints/auth.py
# -------------------------------
cat > src/launchmate/api/v1/endpoints/auth.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel, EmailStr
import uuid
from ....core.database import get_db
from ....core.security import get_password_hash, verify_password, create_access_token
from ....models.user import User, UserRole

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
EOF

# -------------------------------
# api/v1/endpoints/users.py
# -------------------------------
cat > src/launchmate/api/v1/endpoints/users.py << 'EOF'
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
EOF

# -------------------------------
# api/v1/endpoints/projects.py (basic CRUD)
# -------------------------------
cat > src/launchmate/api/v1/endpoints/projects.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime
import uuid
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project, ProjectStatus, ProjectLockStatus
from ....models.version import Version, VersionType

router = APIRouter()

class ProjectCreate(BaseModel):
    core_premise: str
    primary_market: str
    initial_budget: int
    budget_label: str
    market_vectors: List[str]

class ProjectResponse(BaseModel):
    id: str
    name: str
    status: str
    completion: int
    version_count: int
    lock_status: str
    market_vectors: List[str]
    created_at: datetime
    updated_at: datetime

class ProjectListResponse(BaseModel):
    data: List[ProjectResponse]
    total: int
    page: int
    per_page: int
    total_pages: int

def generate_project_name() -> str:
    return "Untitled Project"

def calculate_completion(project: Project) -> int:
    return 0  # Placeholder

@router.get("/", response_model=ProjectListResponse)
async def list_projects(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    query = select(Project).where(Project.owner_id == current_user.id)
    total_result = await db.execute(select(func.count()).select_from(query.subquery()))
    total = total_result.scalar()
    query = query.offset((page - 1) * per_page).limit(per_page)
    result = await db.execute(query)
    projects = result.scalars().all()
    
    data = []
    for p in projects:
        ver_count = await db.execute(select(func.count(Version.id)).where(Version.project_id == p.id))
        version_count = ver_count.scalar() or 0
        data.append(ProjectResponse(
            id=p.public_id,
            name=p.name,
            status=p.status.value,
            completion=calculate_completion(p),
            version_count=version_count,
            lock_status=p.lock_status.value,
            market_vectors=p.market_vectors,
            created_at=p.created_at,
            updated_at=p.updated_at,
        ))
    return ProjectListResponse(
        data=data,
        total=total,
        page=page,
        per_page=per_page,
        total_pages=(total + per_page - 1) // per_page
    )

@router.post("/", status_code=201)
async def create_project(
    data: ProjectCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    project_id = str(uuid.uuid4())
    public_id = f"prj_{uuid.uuid4().hex[:8]}"
    name = generate_project_name()
    
    project = Project(
        id=project_id,
        public_id=public_id,
        owner_id=current_user.id,
        name=name,
        status=ProjectStatus.IDEATION,
        lock_status=ProjectLockStatus.UNLOCKED,
        core_premise=data.core_premise,
        primary_market=data.primary_market,
        initial_budget=data.initial_budget,
        budget_label=data.budget_label,
        market_vectors=data.market_vectors,
    )
    db.add(project)
    await db.flush()
    
    version_id = str(uuid.uuid4())
    version_public_id = f"ver_{uuid.uuid4().hex[:8]}"
    version = Version(
        id=version_id,
        public_id=version_public_id,
        project_id=project.id,
        label="Initial generation",
        type=VersionType.VERSION,
        number=1,
        changes={},
    )
    db.add(version)
    project.current_version_id = version_id
    await db.commit()
    await db.refresh(project)
    
    return {
        "id": project.public_id,
        "name": project.name,
        "status": project.status.value,
        "completion": 0,
        "version_id": version_public_id,
        "generation_job_id": f"job_{uuid.uuid4().hex[:8]}",
        "message": "Project initialized. Generation will start shortly."
    }

@router.get("/{project_id}")
async def get_project(
    project_id: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = result.scalar_one_or_none()
    if not project:
        raise HTTPException(404, "Project not found")
    ver_count = await db.execute(select(func.count(Version.id)).where(Version.project_id == project.id))
    version_count = ver_count.scalar() or 0
    return {
        "id": project.public_id,
        "name": project.name,
        "status": project.status.value,
        "completion": calculate_completion(project),
        "version_count": version_count,
        "current_version_id": project.current_version_id,
        "lock_status": project.lock_status.value,
        "market_vectors": project.market_vectors,
        "parameters": {
            "core_premise": project.core_premise,
            "primary_market": project.primary_market,
            "initial_budget": project.initial_budget,
            "budget_label": project.budget_label,
        },
        "sections": {},
        "open_threads_count": 0,
        "created_at": project.created_at,
        "updated_at": project.updated_at,
    }
EOF

# -------------------------------
# Update main.py to include routers
# -------------------------------
cat > src/launchmate/main.py << 'EOF'
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from .api.v1 import router as api_router
from .core.database import engine, Base
from .core.config import settings

app = FastAPI(title="LaunchMate API", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
async def startup():
    # Create tables if they don't exist (for development)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

app.include_router(api_router)

@app.get("/health")
async def health():
    return {"status": "ok"}
EOF

echo "✅ Phase 4 complete. Restart the backend and test:"
echo "   export PYTHONPATH=src"
echo "   poetry run uvicorn launchmate.main:app --reload"
echo ""
echo "Test endpoints:"
echo "   curl -X POST http://localhost:8000/api/v1/auth/register -H 'Content-Type: application/json' -d '{\"name\":\"Test User\",\"email\":\"test@example.com\",\"password\":\"secret\"}'"
echo "   curl http://localhost:8000/api/v1/users/me -H 'Authorization: Bearer <token>'"
echo "   curl -X POST http://localhost:8000/api/v1/projects -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' -d '{\"core_premise\":\"AI SaaS\",\"primary_market\":\"Global\",\"initial_budget\":10000,\"budget_label\":\"$10k\",\"market_vectors\":[\"AI\",\"B2B\"]}'"