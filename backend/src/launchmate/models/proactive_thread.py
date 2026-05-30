from sqlalchemy import String, Enum, ForeignKey, DateTime, Text, func
from .enums import ProactiveStatus
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

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
