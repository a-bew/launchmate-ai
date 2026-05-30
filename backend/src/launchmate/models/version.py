from sqlalchemy import String, Enum, Integer, ForeignKey, DateTime, JSON, func
from .enums import VersionType
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

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
    
    project = relationship("Project", back_populates="versions", foreign_keys="Version.project_id")
    parent = relationship("Version", remote_side=[id])
    market_research = relationship("MarketResearch", back_populates="version", uselist=False, cascade="all, delete-orphan")
    financials = relationship("Financials", back_populates="version", uselist=False, cascade="all, delete-orphan")
    brand_kit = relationship("BrandKit", back_populates="version", uselist=False, cascade="all, delete-orphan")
    tech_setup = relationship("TechSetup", back_populates="version", uselist=False, cascade="all, delete-orphan")
