from sqlalchemy import String, Enum, ForeignKey, DateTime, JSON, func
from .enums import SectionLockStatus
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
