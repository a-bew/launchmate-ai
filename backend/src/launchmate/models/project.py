from sqlalchemy import String, Enum, Integer, ForeignKey, DateTime, func, JSON, ARRAY
from .enums import ProjectStatus, ProjectLockStatus
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

class Project(Base):
    __tablename__ = "projects"
    
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    public_id: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    owner_id: Mapped[str] = mapped_column(String(36), ForeignKey("users.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    status: Mapped[ProjectStatus] = mapped_column(Enum(ProjectStatus), default=ProjectStatus.IDEATION)
    lock_status: Mapped[ProjectLockStatus] = mapped_column(Enum(ProjectLockStatus), default=ProjectLockStatus.UNLOCKED)
    # current_version_id: Mapped[str] = mapped_column(String(36), ForeignKey("versions.id", use_alter=True, name="fk_project_current_version"), nullable=True)
    current_version_id = mapped_column(
        String(36),
        ForeignKey("versions.id", use_alter=True, name="fk_project_current_version")
    )
    core_premise: Mapped[str] = mapped_column(String(1000), nullable=False)
    primary_market: Mapped[str] = mapped_column(String(255), nullable=False)
    initial_budget: Mapped[int] = mapped_column(Integer, nullable=False)
    budget_label: Mapped[str] = mapped_column(String(50), nullable=False)
    market_vectors: Mapped[list] = mapped_column(ARRAY(String), nullable=False, default=list)
    celery_task_id: Mapped[str] = mapped_column(String(255), nullable=True)
    
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    owner = relationship("User", back_populates="projects")
    versions = relationship("Version", back_populates="project", foreign_keys="Version.project_id", cascade="all, delete-orphan")
    current_version = relationship("Version", foreign_keys=[current_version_id])
    threads = relationship("Thread", back_populates="project", cascade="all, delete-orphan")
    refinements = relationship("Refinement", back_populates="project", cascade="all, delete-orphan")
    amendments = relationship("Amendment", back_populates="project", cascade="all, delete-orphan")
    proactive_threads = relationship("ProactiveThread", back_populates="project", cascade="all, delete-orphan")
    
