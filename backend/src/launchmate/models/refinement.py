from sqlalchemy import String, Enum, ForeignKey, DateTime, Text, JSON, func
from .enums import RefinementStatus
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

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
