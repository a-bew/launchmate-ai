from sqlalchemy import String, Enum, ForeignKey, DateTime, Text, func
from .enums import AmendmentSourceType, AmendmentStatus
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

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
