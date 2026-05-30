import asyncio
import os
import io
from celery import shared_task
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from reportlab.lib.pagesizes import letter
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer
from reportlab.lib.styles import getSampleStyleSheet
from ..core.database import AsyncSessionLocal
from ..models.project import Project
from ..models.version import Version
from ..models.market_research import MarketResearch
from ..models.financials import Financials
from ..core.config import settings
import boto3
from botocore.exceptions import ClientError

@shared_task
def generate_founder_brief(project_id: str):
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Project).where(Project.id == project_id))
            project = result.scalar_one_or_none()
            if not project:
                raise ValueError(f"Project {project_id} not found")
            if not project.current_version_id:
                raise ValueError("No current version")
            version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
            version = version_result.scalar_one()
            mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
            mr = mr_result.scalar_one_or_none()
            fin_result = await db.execute(select(Financials).where(Financials.version_id == version.id))
            fin = fin_result.scalar_one_or_none()
            
            buffer = io.BytesIO()
            doc = SimpleDocTemplate(buffer, pagesize=letter)
            styles = getSampleStyleSheet()
            story = []
            story.append(Paragraph(f"Founder Brief: {project.name}", styles['Title']))
            story.append(Spacer(1, 12))
            story.append(Paragraph(f"Core Premise: {project.core_premise}", styles['Normal']))
            story.append(Paragraph(f"Primary Market: {project.primary_market}", styles['Normal']))
            story.append(Paragraph(f"Initial Budget: ${project.initial_budget}", styles['Normal']))
            story.append(Spacer(1, 12))
            if mr:
                story.append(Paragraph("Market Research", styles['Heading2']))
                story.append(Paragraph(f"Signals: {mr.signals}", styles['Normal']))
                story.append(Paragraph(f"Competitors: {mr.competitors}", styles['Normal']))
            if fin:
                story.append(Paragraph("Financials", styles['Heading2']))
                story.append(Paragraph(f"Cost Breakdown: {fin.cost_breakdown}", styles['Normal']))
                story.append(Paragraph(f"Calculated: {fin.calculated}", styles['Normal']))
            doc.build(story)
            pdf_bytes = buffer.getvalue()
            
            backend = settings.STORAGE_BACKEND
            if backend == "local":
                os.makedirs("./storage/briefs", exist_ok=True)
                with open(f"./storage/briefs/{project.public_id}.pdf", "wb") as f:
                    f.write(pdf_bytes)
            elif backend == "s3":
                s3_kwargs = {
                    "aws_access_key_id": settings.AWS_ACCESS_KEY_ID,
                    "aws_secret_access_key": settings.AWS_SECRET_ACCESS_KEY,
                    "region_name": settings.AWS_REGION,
                }
                if settings.AWS_ENDPOINT_URL:
                    s3_kwargs["endpoint_url"] = settings.AWS_ENDPOINT_URL

                s3 = boto3.client("s3", **s3_kwargs)
                s3.put_object(
                    Bucket=settings.AWS_BUCKET,
                    Key=f"briefs/{project.public_id}.pdf",
                    Body=pdf_bytes,
                    ContentType="application/pdf",
                )
            else:
                raise ValueError(f"Unknown storage backend: {backend}")
            return {"project_id": project.public_id, "status": "ready"}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())
