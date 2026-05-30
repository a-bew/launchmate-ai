from fastapi import APIRouter, Depends, HTTPException, Header
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from pydantic import BaseModel
import uuid
from datetime import datetime
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.thread import Thread, ThreadStatus, Message
from ....models.amendment import Amendment, AmendmentStatus
from ....models.version import Version
from ....models.market_research import MarketResearch
from ....models.financials import Financials
from ....tools.agent import run_signal_sight
from ....core.exceptions import NotFoundError

router = APIRouter()

class ThreadCreate(BaseModel):
    name: str
    context_section: str
    context_detail: str
    opening_message: str

class MessageCreate(BaseModel):
    content: str

class PromoteRequest(BaseModel):
    target_section: str
    summary: str

@router.get("/{project_id}/threads")
async def list_threads(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    result = await db.execute(select(Thread).where(Thread.project_id == project.id).order_by(Thread.updated_at.desc()))
    threads = result.scalars().all()
    data = []
    for t in threads:
        msg_count = await db.execute(select(func.count(Message.id)).where(Message.thread_id == t.id))
        preview = t.messages[0].content[:100] if t.messages else ""
        data.append({
            "id": t.public_id,
            "name": t.name,
            "context_section": t.context_section,
            "context_detail": t.context_detail,
            "status": t.status.value,
            "promoted": t.promoted_to_amendment_id is not None,
            "message_count": msg_count.scalar(),
            "preview": preview,
            "created_at": t.created_at.isoformat(),
            "updated_at": t.updated_at.isoformat()
        })
    return {"project_id": project.public_id, "threads": data, "total": len(data)}

@router.post("/{project_id}/threads", status_code=201)
async def create_thread(project_id: str, data: ThreadCreate, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    thread_id = str(uuid.uuid4())
    public_id = f"thr_{uuid.uuid4().hex[:8]}"
    thread = Thread(
        id=thread_id,
        public_id=public_id,
        project_id=project.id,
        name=data.name,
        context_section=data.context_section,
        context_detail=data.context_detail,
        status=ThreadStatus.OPEN,
        summary=None,
    )
    db.add(thread)
    await db.flush()
    user_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread_id,
        role="user",
        content=data.opening_message,
        idempotency_key=str(uuid.uuid4())
    )
    db.add(user_msg)
    # Get context for agent
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = version_result.scalar_one()
    section_data = {}
    if data.context_section == "market_research":
        mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
        mr = mr_result.scalar_one_or_none()
        section_data = mr.dict() if mr else {}
    elif data.context_section == "financials":
        fin_result = await db.execute(select(Financials).where(Financials.version_id == version.id))
        fin = fin_result.scalar_one_or_none()
        section_data = fin.dict() if fin else {}
    context_prompt = f"Project: {project.name}\nCore premise: {project.core_premise}\nPrimary market: {project.primary_market}\nSection: {data.context_section}\nDetail: {data.context_detail}\nSection data: {section_data}\nUser question: {data.opening_message}\nAnswer using web search if needed."
    agent_result = run_signal_sight(context_prompt)
    assistant_content = agent_result["research"] if "research" in agent_result else "I'm sorry, I couldn't process that."
    assistant_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread_id,
        role="assistant",
        content=assistant_content[:2000],
        idempotency_key=str(uuid.uuid4())
    )
    db.add(assistant_msg)
    await db.commit()
    return {
        "id": public_id,
        "name": data.name,
        "context_section": data.context_section,
        "context_detail": data.context_detail,
        "status": "open",
        "messages": [
            {"id": user_msg.id, "role": "user", "content": user_msg.content, "created_at": user_msg.created_at.isoformat()},
            {"id": assistant_msg.id, "role": "assistant", "content": assistant_msg.content, "created_at": assistant_msg.created_at.isoformat()}
        ],
        "created_at": thread.created_at.isoformat()
    }

@router.get("/projects/threads/{thread_id}")
async def get_thread(thread_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Thread).where(Thread.public_id == thread_id))
    thread = result.scalar_one_or_none()
    if not thread:
        raise NotFoundError("Thread", thread_id)
    p_result = await db.execute(select(Project).where(Project.id == thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    messages_result = await db.execute(select(Message).where(Message.thread_id == thread.id).order_by(Message.created_at))
    messages = messages_result.scalars().all()
    return {
        "id": thread.public_id,
        "name": thread.name,
        "context_section": thread.context_section,
        "context_detail": thread.context_detail,
        "status": thread.status.value,
        "promoted": thread.promoted_to_amendment_id is not None,
        "messages": [{"id": m.id, "role": m.role, "content": m.content, "created_at": m.created_at.isoformat()} for m in messages],
        "created_at": thread.created_at.isoformat(),
        "updated_at": thread.updated_at.isoformat()
    }

@router.post("/projects/threads/{thread_id}/messages")
async def add_message(thread_id: str, data: MessageCreate, idempotency_key: str = Header(...), current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    t_result = await db.execute(select(Thread).where(Thread.public_id == thread_id))
    thread = t_result.scalar_one_or_none()
    if not thread:
        raise NotFoundError("Thread", thread_id)
    p_result = await db.execute(select(Project).where(Project.id == thread.project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise HTTPException(403, "Forbidden")
    existing = await db.execute(select(Message).where(Message.thread_id == thread.id, Message.idempotency_key == idempotency_key))
    if existing.scalar_one_or_none():
        last_msgs = await db.execute(select(Message).where(Message.thread_id == thread.id).order_by(Message.created_at.desc()).limit(2))
        msgs = list(last_msgs.scalars().all())
        msgs.reverse()
        return {
            "user_message": {"id": msgs[0].id, "role": msgs[0].role, "content": msgs[0].content, "created_at": msgs[0].created_at.isoformat()} if len(msgs) > 0 else None,
            "assistant_message": {"id": msgs[1].id, "role": msgs[1].role, "content": msgs[1].content, "created_at": msgs[1].created_at.isoformat()} if len(msgs) > 1 else None
        }
    user_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread.id,
        role="user",
        content=data.content,
        idempotency_key=idempotency_key
    )
    db.add(user_msg)
    await db.flush()
    # Build context for agent
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = version_result.scalar_one()
    section_data = {}
    if thread.context_section == "market_research":
        mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
        mr = mr_result.scalar_one_or_none()
        section_data = mr.dict() if mr else {}
    elif thread.context_section == "financials":
        fin_result = await db.execute(select(Financials).where(Financials.version_id == version.id))
        fin = fin_result.scalar_one_or_none()
        section_data = fin.dict() if fin else {}
    history_result = await db.execute(select(Message).where(Message.thread_id == thread.id).order_by(Message.created_at.desc()).limit(10))
    history_msgs = list(history_result.scalars().all())
    history_msgs.reverse()
    history_text = "\n".join([f"{m.role}: {m.content}" for m in history_msgs])
    context_prompt = f"Project: {project.name}\nCore premise: {project.core_premise}\nPrimary market: {project.primary_market}\nSection: {thread.context_section}\nDetail: {thread.context_detail}\nSection data: {section_data}\nConversation history:\n{history_text}\nUser: {data.content}\nAnswer the user's question using web search if needed."
    agent_result = run_signal_sight(context_prompt)
    assistant_content = agent_result["research"] if "research" in agent_result else "I'm sorry, I couldn't process that."
    assistant_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread.id,
        role="assistant",
        content=assistant_content[:2000],
        idempotency_key=str(uuid.uuid4())
    )
    db.add(assistant_msg)
    thread.updated_at = datetime.utcnow()
    await db.commit()
    return {
        "user_message": {"id": user_msg.id, "role": "user", "content": user_msg.content, "created_at": user_msg.created_at.isoformat()},
        "assistant_message": {"id": assistant_msg.id, "role": "assistant", "content": assistant_msg.content, "created_at": assistant_msg.created_at.isoformat()}
    }

@router.post("/projects/threads/{thread_id}/promote")
async def promote_thread(thread_id: str, data: PromoteRequest, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    t_result = await db.execute(select(Thread).where(Thread.public_id == thread_id))
    thread = t_result.scalar_one_or_none()
    if not thread:
        raise NotFoundError("Thread", thread_id)
    p_result = await db.execute(select(Project).where(Project.id == thread.project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise HTTPException(403, "Forbidden")
    amendment_id = str(uuid.uuid4())
    public_id = f"amd_{uuid.uuid4().hex[:8]}"
    amendment = Amendment(
        id=amendment_id,
        public_id=public_id,
        project_id=project.id,
        source_type="thread",
        source_id=thread.id,
        target_section=data.target_section,
        summary=data.summary,
        status=AmendmentStatus.PENDING
    )
    db.add(amendment)
    thread.promoted_to_amendment_id = amendment_id
    thread.status = ThreadStatus.PROMOTED
    await db.commit()
    return {
        "thread_id": thread.public_id,
        "amendment_id": public_id,
        "promoted": True,
        "target_section": data.target_section,
        "status": "pending_review",
        "message": "Amendment created and pending your review"
    }

@router.delete("/projects/threads/{thread_id}")
async def delete_thread(thread_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    t_result = await db.execute(select(Thread).where(Thread.public_id == thread_id))
    thread = t_result.scalar_one_or_none()
    if not thread:
        raise NotFoundError("Thread", thread_id)
    p_result = await db.execute(select(Project).where(Project.id == thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    await db.delete(thread)
    await db.commit()
    return {"deleted_id": thread_id}
