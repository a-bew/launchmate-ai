import sqlalchemy
from sqlalchemy import String, Enum, ForeignKey, DateTime, Text, func
from .enums import ThreadStatus
from sqlalchemy.orm import Mapped, mapped_column, relationship
from uuid import uuid4
from datetime import datetime
import enum
from ..core.database import Base

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
