import asyncio
from celery import shared_task
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..core.database import AsyncSessionLocal
from ..models.project import Project
from ..models.version import Version
from ..models.brand_kit import BrandKit

@shared_task
def register_domains(project_id: str, handles: list):
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Project).where(Project.id == project_id))
            project = result.scalar_one_or_none()
            if not project:
                return {"error": "Project not found"}
            if not project.current_version_id:
                return {"error": "No current version"}
            version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
            version = version_result.scalar_one()
            bk_result = await db.execute(select(BrandKit).where(BrandKit.version_id == version.id))
            bk = bk_result.scalar_one_or_none()
            if not bk:
                bk = BrandKit(version_id=version.id)
                db.add(bk)
                await db.flush()
            for handle in handles:
                for item in bk.namespace:
                    if item.get("handle") == handle:
                        item["available"] = False
            await db.commit()
            return {"registered": handles, "failed": []}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())
