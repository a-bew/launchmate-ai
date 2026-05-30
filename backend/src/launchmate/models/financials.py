from sqlalchemy import String, Enum, ForeignKey, DateTime, JSON, func
from .enums import SectionLockStatus
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
