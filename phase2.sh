#!/bin/bash
set -e

echo "📦 Phase 2: Database Models, Config, and Alembic Migration"

# Ensure we are in the backend directory
cd backend

# -------------------------------
# core/config.py
# -------------------------------
mkdir -p src/launchmate/core
cat > src/launchmate/core/config.py << 'EOF'
from pydantic_settings import BaseSettings
from pydantic import Field
from typing import Optional

class Settings(BaseSettings):
    # Database
    DATABASE_URL: str = "postgresql+asyncpg://launchmate:launchmate@db:5432/launchmate"
    
    # Redis
    REDIS_URL: str = "redis://redis:6379/0"
    
    # JWT
    SECRET_KEY: str = Field(..., min_length=32)
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    
    # Bright Data
    BRIGHTDATA_API_KEY: str = ""
    SERP_ZONE: str = "serp_api2"
    UNLOCKER_ZONE: str = "web_unlocker1"
    
    # LLM
    OPENROUTER_API_KEY: str = ""
    LLM_MODEL: str = "step-3.5-flash"
    
    # Celery (default to Redis)
    CELERY_BROKER_URL: Optional[str] = None
    CELERY_RESULT_BACKEND: Optional[str] = None
    
    # PDF Storage
    STORAGE_BACKEND: str = "local"  # local or s3
    AWS_BUCKET: str = ""
    AWS_ACCESS_KEY_ID: str = ""
    AWS_SECRET_ACCESS_KEY: str = ""
    AWS_REGION: str = "us-east-1"
    
    class Config:
        env_file = ".env"
        extra = "ignore"

settings = Settings()
EOF

# -------------------------------
# core/database.py
# -------------------------------
cat > src/launchmate/core/database.py << 'EOF'
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import declarative_base
from .config import settings

engine = create_async_engine(
    settings.DATABASE_URL,
    echo=True,
    pool_size=20,
    max_overflow=10,
)

AsyncSessionLocal = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
)

Base = declarative_base()

async def get_db() -> AsyncSession:
    async with AsyncSessionLocal() as session:
        yield session
EOF

# -------------------------------
# core/security.py
# -------------------------------
cat > src/launchmate/core/security.py << 'EOF'
from datetime import datetime, timedelta, timezone
from typing import Optional
from jose import JWTError, jwt
from passlib.context import CryptContext
from .config import settings

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def verify_password(plain_password: str, hashed_password: str) -> bool:
    return pwd_context.verify(plain_password, hashed_password)

def get_password_hash(password: str) -> str:
    return pwd_context.hash(password)

def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    to_encode = data.copy()
    if expires_delta:
        expire = datetime.now(timezone.utc) + expires_delta
    else:
        expire = datetime.now(timezone.utc) + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)
    return encoded_jwt

def decode_access_token(token: str) -> dict:
    return jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
EOF

# -------------------------------
# core/exceptions.py
# -------------------------------
cat > src/launchmate/core/exceptions.py << 'EOF'
class AppException(Exception):
    def __init__(self, status_code: int, error_code: str, message: str, field: str = None):
        self.status_code = status_code
        self.error_code = error_code
        self.message = message
        self.field = field

class LockedSectionError(AppException):
    def __init__(self, section: str):
        super().__init__(403, "forbidden", f"Section {section} is locked. Unlock before editing.", field=section)

class ConflictError(AppException):
    def __init__(self, message: str):
        super().__init__(409, "conflict", message)

class NotFoundError(AppException):
    def __init__(self, resource: str, id: str):
        super().__init__(404, "not_found", f"{resource} not found: {id}")

class ValidationError(AppException):
    def __init__(self, message: str, field: str = None):
        super().__init__(422, "validation_error", message, field=field)
EOF

# -------------------------------
# models/__init__.py
# -------------------------------
mkdir -p src/launchmate/models
cat > src/launchmate/models/__init__.py << 'EOF'
from .user import User
from .project import Project
from .version import Version
from .market_research import MarketResearch
from .financials import Financials
from .brand_kit import BrandKit
from .tech_setup import TechSetup
from .thread import Thread, Message
from .refinement import Refinement
from .amendment import Amendment
from .proactive_thread import ProactiveThread
EOF

# -------------------------------
# models/user.py
# -------------------------------
cat > src/launchmate/models/user.py << 'EOF'
from sqlalchemy import String, Enum, DateTime, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class UserRole(str, enum.Enum):
    PRO_ARCHITECT = "Pro Architect"
    BUILDER = "Builder"

class User(Base):
    __tablename__ = "users"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    public_id: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(100), nullable=False)
    email: Mapped[str] = mapped_column(String(255), unique=True, nullable=False, index=True)
    hashed_password: Mapped[str] = mapped_column(String(255), nullable=False)
    role: Mapped[UserRole] = mapped_column(Enum(UserRole), default=UserRole.BUILDER)
    avatar_initials: Mapped[str] = mapped_column(String(10), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    
    projects = relationship("Project", back_populates="owner", cascade="all, delete-orphan")
EOF

# -------------------------------
# models/project.py
# -------------------------------
cat > src/launchmate/models/project.py << 'EOF'
from sqlalchemy import String, Enum, Integer, ForeignKey, DateTime, func, JSON, ARRAY
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class ProjectStatus(str, enum.Enum):
    IDEATION = "ideation"
    DRAFT = "draft"
    ACTIVE = "active"
    ARCHIVED = "archived"

class ProjectLockStatus(str, enum.Enum):
    LOCKED = "locked"
    UNLOCKED = "unlocked"

class Project(Base):
    __tablename__ = "projects"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    public_id: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    owner_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    status: Mapped[ProjectStatus] = mapped_column(Enum(ProjectStatus), default=ProjectStatus.IDEATION)
    lock_status: Mapped[ProjectLockStatus] = mapped_column(Enum(ProjectLockStatus), default=ProjectLockStatus.UNLOCKED)
    current_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("versions.id"), nullable=True)
    
    core_premise: Mapped[str] = mapped_column(String(1000), nullable=False)
    primary_market: Mapped[str] = mapped_column(String(255), nullable=False)
    initial_budget: Mapped[int] = mapped_column(Integer, nullable=False)
    budget_label: Mapped[str] = mapped_column(String(50), nullable=False)
    market_vectors: Mapped[list] = mapped_column(ARRAY(String), nullable=False, default=list)
    celery_task_id: Mapped[str] = mapped_column(String(255), nullable=True)
    
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    owner = relationship("User", back_populates="projects")
    versions = relationship("Version", back_populates="project", cascade="all, delete-orphan")
    current_version = relationship("Version", foreign_keys=[current_version_id])
    threads = relationship("Thread", back_populates="project", cascade="all, delete-orphan")
    refinements = relationship("Refinement", back_populates="project", cascade="all, delete-orphan")
    amendments = relationship("Amendment", back_populates="project", cascade="all, delete-orphan")
    proactive_threads = relationship("ProactiveThread", back_populates="project", cascade="all, delete-orphan")
EOF

# -------------------------------
# models/version.py
# -------------------------------
cat > src/launchmate/models/version.py << 'EOF'
from sqlalchemy import String, Enum, Integer, ForeignKey, DateTime, JSON, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class VersionType(str, enum.Enum):
    VERSION = "version"
    BRANCH = "branch"

class Version(Base):
    __tablename__ = "versions"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    public_id: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    project_id: Mapped[str] = mapped_column(String(36), ForeignKey("projects.id"), nullable=False)
    parent_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("versions.id"), nullable=True)
    branch_id: Mapped[str] = mapped_column(String(50), nullable=True)
    label: Mapped[str] = mapped_column(String(255), nullable=False)
    type: Mapped[VersionType] = mapped_column(Enum(VersionType), default=VersionType.VERSION)
    number: Mapped[int] = mapped_column(Integer, nullable=True)
    changes: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    
    project = relationship("Project", back_populates="versions")
    parent = relationship("Version", remote_side=[id])
    market_research = relationship("MarketResearch", back_populates="version", uselist=False, cascade="all, delete-orphan")
    financials = relationship("Financials", back_populates="version", uselist=False, cascade="all, delete-orphan")
    brand_kit = relationship("BrandKit", back_populates="version", uselist=False, cascade="all, delete-orphan")
    tech_setup = relationship("TechSetup", back_populates="version", uselist=False, cascade="all, delete-orphan")
EOF

# -------------------------------
# models/market_research.py
# -------------------------------
cat > src/launchmate/models/market_research.py << 'EOF'
from sqlalchemy import String, Enum, ForeignKey, DateTime, JSON, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class SectionLockStatus(str, enum.Enum):
    LOCKED = "locked"
    UNLOCKED = "unlocked"
    DRAFT = "draft"

class MarketResearch(Base):
    __tablename__ = "market_research"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    version_id: Mapped[str] = mapped_column(String(36), ForeignKey("versions.id"), unique=True, nullable=False)
    lock_status: Mapped[SectionLockStatus] = mapped_column(Enum(SectionLockStatus), default=SectionLockStatus.UNLOCKED)
    signals: Mapped[list] = mapped_column(JSON, default=list)
    competitors: Mapped[list] = mapped_column(JSON, default=list)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    version = relationship("Version", back_populates="market_research")
EOF

# -------------------------------
# models/financials.py
# -------------------------------
cat > src/launchmate/models/financials.py << 'EOF'
from sqlalchemy import String, Enum, ForeignKey, DateTime, JSON, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class Financials(Base):
    __tablename__ = "financials"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    version_id: Mapped[str] = mapped_column(String(36), ForeignKey("versions.id"), unique=True, nullable=False)
    lock_status: Mapped[SectionLockStatus] = mapped_column(Enum(SectionLockStatus), default=SectionLockStatus.UNLOCKED)
    cost_breakdown: Mapped[list] = mapped_column(JSON, default=list)  # each item: {id, name, type, amount, tag}
    calculated: Mapped[dict] = mapped_column(JSON, default=dict)
    break_even: Mapped[dict] = mapped_column(JSON, default=dict)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    version = relationship("Version", back_populates="financials")
EOF

# -------------------------------
# models/brand_kit.py
# -------------------------------
cat > src/launchmate/models/brand_kit.py << 'EOF'
from sqlalchemy import String, Enum, ForeignKey, DateTime, JSON, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class BrandKit(Base):
    __tablename__ = "brand_kit"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    version_id: Mapped[str] = mapped_column(String(36), ForeignKey("versions.id"), unique=True, nullable=False)
    lock_status: Mapped[SectionLockStatus] = mapped_column(Enum(SectionLockStatus), default=SectionLockStatus.UNLOCKED)
    namespace: Mapped[list] = mapped_column(JSON, default=list)  # {platform, handle, available}
    typography: Mapped[dict] = mapped_column(JSON, default=dict)
    logo_options: Mapped[list] = mapped_column(JSON, default=list)
    selected_logo_id: Mapped[str] = mapped_column(String(50), nullable=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    version = relationship("Version", back_populates="brand_kit")
EOF

# -------------------------------
# models/tech_setup.py
# -------------------------------
cat > src/launchmate/models/tech_setup.py << 'EOF'
from sqlalchemy import String, Enum, ForeignKey, DateTime, JSON, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class TechSetup(Base):
    __tablename__ = "tech_setup"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    version_id: Mapped[str] = mapped_column(String(36), ForeignKey("versions.id"), unique=True, nullable=False)
    lock_status: Mapped[SectionLockStatus] = mapped_column(Enum(SectionLockStatus), default=SectionLockStatus.UNLOCKED)
    online_presence: Mapped[dict] = mapped_column(JSON, default=dict)
    automations: Mapped[dict] = mapped_column(JSON, default=dict)
    store: Mapped[dict] = mapped_column(JSON, default=dict)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    version = relationship("Version", back_populates="tech_setup")
EOF

# -------------------------------
# models/thread.py
# -------------------------------
cat > src/launchmate/models/thread.py << 'EOF'
from sqlalchemy import String, Enum, ForeignKey, DateTime, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class ThreadStatus(str, enum.Enum):
    OPEN = "open"
    CLOSED = "closed"
    PROMOTED = "promoted"

class Thread(Base):
    __tablename__ = "threads"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    public_id: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    project_id: Mapped[str] = mapped_column(String(36), ForeignKey("projects.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    context_section: Mapped[str] = mapped_column(String(100), nullable=False)
    context_detail: Mapped[str] = mapped_column(String(255), nullable=False)
    status: Mapped[ThreadStatus] = mapped_column(Enum(ThreadStatus), default=ThreadStatus.OPEN)
    summary: Mapped[str] = mapped_column(Text, nullable=True)  # generated after 10 messages
    promoted_to_amendment_id: Mapped[str] = mapped_column(String(36), ForeignKey("amendments.id"), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    project = relationship("Project", back_populates="threads")
    messages = relationship("Message", back_populates="thread", cascade="all, delete-orphan")
    promoted_to_amendment = relationship("Amendment", foreign_keys=[promoted_to_amendment_id])

class Message(Base):
    __tablename__ = "messages"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    thread_id: Mapped[str] = mapped_column(String(36), ForeignKey("threads.id"), nullable=False)
    role: Mapped[str] = mapped_column(Enum("user", "assistant", name="message_role"), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(36), nullable=False)  # UUID from header
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    
    thread = relationship("Thread", back_populates="messages")
    
    __table_args__ = (sqlalchemy.UniqueConstraint('thread_id', 'idempotency_key'),)
EOF

# -------------------------------
# models/refinement.py
# -------------------------------
cat > src/launchmate/models/refinement.py << 'EOF'
from sqlalchemy import String, Enum, ForeignKey, DateTime, Text, JSON, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class RefinementStatus(str, enum.Enum):
    PENDING = "pending_review"
    ACCEPTED = "accepted"
    REJECTED = "rejected"

class Refinement(Base):
    __tablename__ = "refinements"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    public_id: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    project_id: Mapped[str] = mapped_column(String(36), ForeignKey("projects.id"), nullable=False)
    target_section: Mapped[str] = mapped_column(String(100), nullable=False)
    target_element: Mapped[str] = mapped_column(String(100), nullable=False)
    target_id: Mapped[str] = mapped_column(String(100), nullable=True)
    instruction: Mapped[str] = mapped_column(Text, nullable=False)
    diff_before: Mapped[str] = mapped_column(Text, nullable=False)
    diff_after: Mapped[str] = mapped_column(Text, nullable=False)
    ripple_preview: Mapped[dict] = mapped_column(JSON, default=dict)
    status: Mapped[RefinementStatus] = mapped_column(Enum(RefinementStatus), default=RefinementStatus.PENDING)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    
    project = relationship("Project", back_populates="refinements")
EOF

# -------------------------------
# models/amendment.py
# -------------------------------
cat > src/launchmate/models/amendment.py << 'EOF'
from sqlalchemy import String, Enum, ForeignKey, DateTime, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class AmendmentSourceType(str, enum.Enum):
    THREAD = "thread"
    REFINEMENT = "refinement"

class AmendmentStatus(str, enum.Enum):
    PENDING = "pending_review"
    ACCEPTED = "accepted"
    REJECTED = "rejected"

class Amendment(Base):
    __tablename__ = "amendments"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    public_id: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    project_id: Mapped[str] = mapped_column(String(36), ForeignKey("projects.id"), nullable=False)
    source_type: Mapped[AmendmentSourceType] = mapped_column(Enum(AmendmentSourceType), nullable=False)
    source_id: Mapped[str] = mapped_column(String(36), nullable=False)  # thread_id or refinement_id
    target_section: Mapped[str] = mapped_column(String(100), nullable=False)
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[AmendmentStatus] = mapped_column(Enum(AmendmentStatus), default=AmendmentStatus.PENDING)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    
    project = relationship("Project", back_populates="amendments")
EOF

# -------------------------------
# models/proactive_thread.py
# -------------------------------
cat > src/launchmate/models/proactive_thread.py << 'EOF'
from sqlalchemy import String, Enum, ForeignKey, DateTime, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class ProactiveStatus(str, enum.Enum):
    OPEN = "open"
    DISMISSED = "dismissed"
    SNOOZED = "snoozed"

class ProactiveThread(Base):
    __tablename__ = "proactive_threads"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    public_id: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    project_id: Mapped[str] = mapped_column(String(36), ForeignKey("projects.id"), nullable=False)
    question: Mapped[str] = mapped_column(Text, nullable=False)
    source_section: Mapped[str] = mapped_column(String(100), nullable=False)
    source_detail: Mapped[str] = mapped_column(String(255), nullable=False)
    bullet_color: Mapped[str] = mapped_column(Enum("green", "amber", "blue", name="bullet_color"), nullable=False)
    status: Mapped[ProactiveStatus] = mapped_column(Enum(ProactiveStatus), default=ProactiveStatus.OPEN)
    snooze_until: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    
    project = relationship("Project", back_populates="proactive_threads")
EOF

# -------------------------------
# Alembic setup
# -------------------------------
# Install alembic if not already (but we assume poetry install done in Phase 1)
poetry run alembic init alembic 2>/dev/null || true

# Overwrite alembic/env.py to use async engine
cat > alembic/env.py << 'EOF'
import asyncio
from logging.config import fileConfig
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config
from alembic import context

from src.launchmate.core.database import Base
from src.launchmate.core.config import settings

config = context.config
config.set_main_option("sqlalchemy.url", settings.DATABASE_URL)

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata

def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()

def do_run_migrations(connection: Connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata)
    with context.begin_transaction():
        context.run_migrations()

async def run_async_migrations() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()

def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())

if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
EOF

# Generate initial migration (auto detect)
poetry run alembic revision --autogenerate -m "initial schema"
# The generated file will be in alembic/versions/. We won't modify it here; user can apply.

echo "✅ Phase 2 complete. Now run:"
echo "   cd backend"
echo "   make migrate"
echo ""
echo "Verification: "
echo "   make migrate"
echo "   docker compose exec db psql -U launchmate -c \"\\dt\""
echo "Should list all tables: users, projects, versions, market_research, financials, brand_kit, tech_setup, threads, messages, refinements, amendments, proactive_threads"