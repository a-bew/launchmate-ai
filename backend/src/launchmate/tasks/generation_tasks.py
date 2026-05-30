import asyncio
import uuid
from celery import shared_task
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ..core.database import AsyncSessionLocal
from ..models.project import Project, ProjectStatus
from ..models.version import Version
from ..models.market_research import MarketResearch, SectionLockStatus
from ..models.financials import Financials
from ..models.brand_kit import BrandKit
from ..models.tech_setup import TechSetup
from ..tools.agent import run_signal_sight
import json
import logging

logger = logging.getLogger(__name__)

def update_task_progress(task, progress: int, current_step: str, steps_completed: list, steps_remaining: list, estimated_seconds: int = None):
    task.update_state(
        state="PROGRESS",
        meta={
            "progress": progress,
            "current_step": current_step,
            "steps_completed": steps_completed,
            "steps_remaining": steps_remaining,
            "estimated_seconds_remaining": estimated_seconds,
        }
    )

@shared_task(bind=True)
def generate_initial_project(self, project_id: str):
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Project).where(Project.id == project_id))
            project = result.scalar_one_or_none()
            if not project:
                raise ValueError(f"Project {project_id} not found")
            if not project.current_version_id:
                raise ValueError(f"Project {project_id} has no current version")
            version_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
            version = version_result.scalar_one()
            
            params = {
                "core_premise": project.core_premise,
                "primary_market": project.primary_market,
                "initial_budget": project.initial_budget,
                "market_vectors": project.market_vectors,
            }
            sections = ["market_research", "financials", "brand_kit", "tech_setup"]
            total_steps = len(sections)
            steps_completed = []
            
            for idx, section in enumerate(sections):
                update_task_progress(self, int((idx / total_steps) * 100), f"Generating {section}...", steps_completed, sections[idx:], 30)
                # Construct prompt
                if section == "market_research":
                    prompt = f"""Market research for startup: {params['core_premise']} in {params['primary_market']}. Vectors: {params['market_vectors']}. Output JSON with 'signals' and 'competitors' arrays."""
                elif section == "financials":
                    prompt = f"""Financials for startup with budget ${params['initial_budget']}: {params['core_premise']}. Output JSON with 'cost_breakdown', 'calculated', 'break_even'."""
                elif section == "brand_kit":
                    prompt = f"""Brand kit for {project.name}. Output JSON with 'namespace', 'typography', 'logo_options'."""
                else:  # tech_setup
                    prompt = f"""Tech setup for {project.name}. Output JSON with 'online_presence', 'automations', 'store'."""
                
                result = run_signal_sight(prompt)
                if "error" in result["brief"]:
                    raise RuntimeError(f"Agent failed for {section}: {result['brief'].get('error')}")
                data = result["brief"]
                
                if section == "market_research":
                    mr = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
                    mr_rec = mr.scalar_one_or_none()
                    if not mr_rec:
                        mr_rec = MarketResearch(version_id=version.id)
                        db.add(mr_rec)
                    mr_rec.signals = data.get("signals", [])
                    mr_rec.competitors = data.get("competitors", [])
                    mr_rec.lock_status = SectionLockStatus.UNLOCKED
                elif section == "financials":
                    fin = await db.execute(select(Financials).where(Financials.version_id == version.id))
                    fin_rec = fin.scalar_one_or_none()
                    if not fin_rec:
                        fin_rec = Financials(version_id=version.id)
                        db.add(fin_rec)
                    fin_rec.cost_breakdown = data.get("cost_breakdown", [])
                    fin_rec.calculated = data.get("calculated", {})
                    fin_rec.break_even = data.get("break_even", {})
                    fin_rec.lock_status = SectionLockStatus.UNLOCKED
                elif section == "brand_kit":
                    bk = await db.execute(select(BrandKit).where(BrandKit.version_id == version.id))
                    bk_rec = bk.scalar_one_or_none()
                    if not bk_rec:
                        bk_rec = BrandKit(version_id=version.id)
                        db.add(bk_rec)
                    bk_rec.namespace = data.get("namespace", [])
                    bk_rec.typography = data.get("typography", {})
                    bk_rec.logo_options = data.get("logo_options", [])
                    bk_rec.selected_logo_id = None
                    bk_rec.lock_status = SectionLockStatus.UNLOCKED
                else:  # tech_setup
                    ts = await db.execute(select(TechSetup).where(TechSetup.version_id == version.id))
                    ts_rec = ts.scalar_one_or_none()
                    if not ts_rec:
                        ts_rec = TechSetup(version_id=version.id)
                        db.add(ts_rec)
                    ts_rec.online_presence = data.get("online_presence", {})
                    ts_rec.automations = data.get("automations", {})
                    ts_rec.store = data.get("store", {})
                    ts_rec.lock_status = SectionLockStatus.DRAFT
                
                await db.commit()
                steps_completed.append(section)
            
            project.status = ProjectStatus.DRAFT
            await db.commit()
            return {"status": "complete"}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())

@shared_task(bind=True)
def regenerate_section(self, project_id: str, section_name: str, version_id: str):
    async def _run():
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Project).where(Project.id == project_id))
            project = result.scalar_one_or_none()
            if not project:
                raise ValueError(f"Project {project_id} not found")
            version_result = await db.execute(select(Version).where(Version.id == version_id))
            version = version_result.scalar_one()
            params = {
                "core_premise": project.core_premise,
                "primary_market": project.primary_market,
                "initial_budget": project.initial_budget,
                "market_vectors": project.market_vectors,
            }
            prompt_map = {
                "market_research": f"Market research for: {params['core_premise']} in {params['primary_market']}. Vectors: {params['market_vectors']}. Output JSON with signals and competitors.",
                "financials": f"Financials for startup with budget ${params['initial_budget']}, premise: {params['core_premise']}. Output JSON with cost_breakdown, calculated, break_even.",
                "brand_kit": f"Brand kit for {project.name}. Output JSON with namespace, typography, logo_options.",
                "tech_setup": f"Tech setup for {project.name}. Output JSON with online_presence, automations, store.",
            }
            prompt = prompt_map.get(section_name)
            if not prompt:
                raise ValueError(f"Unknown section: {section_name}")
            result = run_signal_sight(prompt)
            if "error" in result["brief"]:
                raise RuntimeError(f"Agent failed for {section_name}: {result['brief'].get('error')}")
            data = result["brief"]
            
            if section_name == "market_research":
                mr = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
                mr_rec = mr.scalar_one_or_none()
                if not mr_rec:
                    mr_rec = MarketResearch(version_id=version.id)
                    db.add(mr_rec)
                mr_rec.signals = data.get("signals", [])
                mr_rec.competitors = data.get("competitors", [])
            elif section_name == "financials":
                fin = await db.execute(select(Financials).where(Financials.version_id == version.id))
                fin_rec = fin.scalar_one_or_none()
                if not fin_rec:
                    fin_rec = Financials(version_id=version.id)
                    db.add(fin_rec)
                fin_rec.cost_breakdown = data.get("cost_breakdown", [])
                fin_rec.calculated = data.get("calculated", {})
                fin_rec.break_even = data.get("break_even", {})
            elif section_name == "brand_kit":
                bk = await db.execute(select(BrandKit).where(BrandKit.version_id == version.id))
                bk_rec = bk.scalar_one_or_none()
                if not bk_rec:
                    bk_rec = BrandKit(version_id=version.id)
                    db.add(bk_rec)
                bk_rec.namespace = data.get("namespace", [])
                bk_rec.typography = data.get("typography", {})
                bk_rec.logo_options = data.get("logo_options", [])
            elif section_name == "tech_setup":
                ts = await db.execute(select(TechSetup).where(TechSetup.version_id == version.id))
                ts_rec = ts.scalar_one_or_none()
                if not ts_rec:
                    ts_rec = TechSetup(version_id=version.id)
                    db.add(ts_rec)
                ts_rec.online_presence = data.get("online_presence", {})
                ts_rec.automations = data.get("automations", {})
                ts_rec.store = data.get("store", {})
            await db.commit()
            return {"section": section_name, "status": "regenerated"}
    
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    return loop.run_until_complete(_run())
