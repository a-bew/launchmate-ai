import asyncio
import uuid
from celery import shared_task
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from ..core.database import AsyncSessionLocal
from ..models.project import Project, ProjectStatus, ProjectLockStatus
from ..models.proactive_thread import ProactiveThread, ProactiveStatus
from ..tools.agent import run_signal_sight
import logging

logger = logging.getLogger(__name__)

@shared_task
def generate_proactive_threads():
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(
                select(Project).where(
                    Project.status == ProjectStatus.ACTIVE,
                    Project.lock_status != ProjectLockStatus.LOCKED
                )
            )
            projects = result.scalars().all()
            for project in projects:
                count_result = await db.execute(
                    select(func.count(ProactiveThread.id)).where(
                        ProactiveThread.project_id == project.id,
                        ProactiveThread.status.in_([ProactiveStatus.OPEN, ProactiveStatus.SNOOZED])
                    )
                )
                existing_count = count_result.scalar() or 0
                if existing_count >= 5:
                    continue
                prompt = f"""For startup "{project.name}": {project.core_premise}. Generate 3-5 questions about market, finances, brand, or tech. Output JSON array: [{{"question":"...","source_section":"market_research|financials|brand_kit|tech_setup","source_detail":"...","bullet_color":"green|amber|blue"}}]"""
                result = run_signal_sight(prompt)
                if "error" in result["brief"]:
                    logger.error(f"Agent failed for project {project.id}: {result['brief'].get('error')}")
                    continue
                items = result["brief"]
                if isinstance(items, dict) and "questions" in items:
                    items = items["questions"]
                if not isinstance(items, list):
                    items = []
                existing_questions = await db.execute(
                    select(ProactiveThread.question).where(ProactiveThread.project_id == project.id)
                )
                existing_set = set(row[0] for row in existing_questions.all())
                new_count = 0
                for item in items[:5]:
                    if new_count + existing_count >= 5:
                        break
                    q = item.get("question", "")
                    if not q or q in existing_set:
                        continue
                    pthr = ProactiveThread(
                        id=str(uuid.uuid4()),
                        public_id=f"pthr_{uuid.uuid4().hex[:8]}",
                        project_id=project.id,
                        question=q,
                        source_section=item.get("source_section", "market_research"),
                        source_detail=item.get("source_detail", "auto-generated"),
                        bullet_color=item.get("bullet_color", "blue"),
                        status=ProactiveStatus.OPEN,
                    )
                    db.add(pthr)
                    new_count += 1
                await db.commit()
        return {"generated": True}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())
