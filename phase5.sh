#!/bin/bash
set -e

echo "📡 Phase 5: All Remaining Endpoints (Sections, Threads, Versions, etc.)"

cd backend

# Create endpoints directory if not exists
mkdir -p src/launchmate/api/v1/endpoints

# ----------------------------------------------------------------------
# 1. market_research.py
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/market_research.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.market_research import MarketResearch, SectionLockStatus
from ....core.exceptions import NotFoundError, LockedSectionError

router = APIRouter()

async def get_current_version_market_research(project_id: str, user_id: str, db: AsyncSession):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    v_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = v_result.scalar_one_or_none()
    if not version:
        raise HTTPException(404, "Version not found")
    mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
    market_research = mr_result.scalar_one_or_none()
    if not market_research:
        market_research = MarketResearch(version_id=version.id, signals=[], competitors=[])
        db.add(market_research)
        await db.commit()
        await db.refresh(market_research)
    return market_research, project

@router.get("/{project_id}/market-research")
async def get_market_research(
    project_id: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    mr, project = await get_current_version_market_research(project_id, current_user.id, db)
    return {
        "project_id": project.public_id,
        "version_id": mr.version_id,
        "lock_status": mr.lock_status.value,
        "signals": mr.signals,
        "competitors": mr.competitors,
        "updated_at": mr.updated_at.isoformat()
    }
EOF

# ----------------------------------------------------------------------
# 2. financials.py
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/financials.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import List, Optional
import uuid
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.financials import Financials, SectionLockStatus
from ....core.exceptions import NotFoundError, LockedSectionError

router = APIRouter()

class ExpenseCreate(BaseModel):
    name: str
    type: str
    amount: float
    tag: Optional[str] = None

class ExpenseUpdate(BaseModel):
    amount: Optional[float] = None
    name: Optional[str] = None
    type: Optional[str] = None
    tag: Optional[str] = None

async def get_current_version_financials(project_id: str, user_id: str, db: AsyncSession):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    v_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = v_result.scalar_one_or_none()
    if not version:
        raise HTTPException(404, "Version not found")
    f_result = await db.execute(select(Financials).where(Financials.version_id == version.id))
    financials = f_result.scalar_one_or_none()
    if not financials:
        financials = Financials(version_id=version.id, cost_breakdown=[], calculated={}, break_even={})
        db.add(financials)
        await db.commit()
        await db.refresh(financials)
    return financials, project

def recalculate_financials(cost_breakdown: list) -> dict:
    monthly_total = sum(item["amount"] for item in cost_breakdown if item.get("type") == "monthly")
    one_time_total = sum(item["amount"] for item in cost_breakdown if item.get("type") == "one_time")
    return {
        "monthly_burn_fixed": monthly_total,
        "day1_setup_costs": one_time_total,
        "six_month_runway": monthly_total * 6,
        "total_capital_required": one_time_total + monthly_total * 6,
    }

@router.get("/{project_id}/financials")
async def get_financials(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    fin, project = await get_current_version_financials(project_id, current_user.id, db)
    return {
        "project_id": project.public_id,
        "version_id": fin.version_id,
        "lock_status": fin.lock_status.value,
        "cost_breakdown": fin.cost_breakdown,
        "calculated": fin.calculated,
        "break_even": fin.break_even,
        "updated_at": fin.updated_at.isoformat()
    }

@router.post("/{project_id}/financials/expenses", status_code=201)
async def add_expense(
    project_id: str,
    expense: ExpenseCreate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    fin, project = await get_current_version_financials(project_id, current_user.id, db)
    if fin.lock_status == SectionLockStatus.LOCKED:
        raise LockedSectionError("financials")
    new_id = f"exp_{uuid.uuid4().hex[:8]}"
    new_item = expense.dict()
    new_item["id"] = new_id
    fin.cost_breakdown.append(new_item)
    fin.calculated = recalculate_financials(fin.cost_breakdown)
    await db.commit()
    return {
        "id": new_id,
        "name": expense.name,
        "type": expense.type,
        "amount": expense.amount,
        "recalculated": fin.calculated,
        "tag": expense.tag,
    }

@router.patch("/{project_id}/financials/expenses/{expense_id}")
async def update_expense(
    project_id: str,
    expense_id: str,
    update: ExpenseUpdate,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    fin, project = await get_current_version_financials(project_id, current_user.id, db)
    if fin.lock_status == SectionLockStatus.LOCKED:
        raise LockedSectionError("financials")
    found = None
    for item in fin.cost_breakdown:
        if item.get("id") == expense_id:
            found = item
            break
    if not found:
        raise NotFoundError("Expense", expense_id)
    if update.amount is not None:
        found["amount"] = update.amount
    if update.name:
        found["name"] = update.name
    if update.type:
        found["type"] = update.type
    if update.tag is not None:
        found["tag"] = update.tag
    fin.calculated = recalculate_financials(fin.cost_breakdown)
    await db.commit()
    return {
        "id": expense_id,
        "amount": found["amount"],
        "recalculated": fin.calculated
    }

@router.delete("/{project_id}/financials/expenses/{expense_id}")
async def delete_expense(
    project_id: str,
    expense_id: str,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    fin, project = await get_current_version_financials(project_id, current_user.id, db)
    if fin.lock_status == SectionLockStatus.LOCKED:
        raise LockedSectionError("financials")
    fin.cost_breakdown = [item for item in fin.cost_breakdown if item.get("id") != expense_id]
    fin.calculated = recalculate_financials(fin.cost_breakdown)
    await db.commit()
    return {
        "deleted_id": expense_id,
        "recalculated": fin.calculated
    }
EOF

# ----------------------------------------------------------------------
# 3. brand_kit.py
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/brand_kit.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import List
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.brand_kit import BrandKit, SectionLockStatus
from ....core.exceptions import NotFoundError, LockedSectionError

router = APIRouter()

class LogoSelect(BaseModel):
    selected_logo_id: str

class NamespaceCheckRequest(BaseModel):
    handles: List[str]

class NamespaceCheckResponse(BaseModel):
    results: dict

async def get_current_version_brand_kit(project_id: str, user_id: str, db: AsyncSession):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    v_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = v_result.scalar_one_or_none()
    if not version:
        raise HTTPException(404, "Version not found")
    bk_result = await db.execute(select(BrandKit).where(BrandKit.version_id == version.id))
    brand_kit = bk_result.scalar_one_or_none()
    if not brand_kit:
        brand_kit = BrandKit(version_id=version.id, namespace=[], typography={}, logo_options=[], selected_logo_id=None)
        db.add(brand_kit)
        await db.commit()
        await db.refresh(brand_kit)
    return brand_kit, project

@router.get("/{project_id}/brand-kit")
async def get_brand_kit(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    bk, project = await get_current_version_brand_kit(project_id, current_user.id, db)
    return {
        "project_id": project.public_id,
        "version_id": bk.version_id,
        "lock_status": bk.lock_status.value,
        "namespace": bk.namespace,
        "typography": bk.typography,
        "logo_options": bk.logo_options,
        "updated_at": bk.updated_at.isoformat()
    }

@router.patch("/{project_id}/brand-kit/logo")
async def select_logo(
    project_id: str,
    data: LogoSelect,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    bk, project = await get_current_version_brand_kit(project_id, current_user.id, db)
    if bk.lock_status == SectionLockStatus.LOCKED:
        raise LockedSectionError("brand_kit")
    bk.selected_logo_id = data.selected_logo_id
    await db.commit()
    return {
        "selected_logo_id": data.selected_logo_id,
        "updated_at": bk.updated_at.isoformat()
    }

@router.post("/{project_id}/brand-kit/register-domains")
async def register_domains(
    project_id: str,
    data: NamespaceCheckRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    bk, project = await get_current_version_brand_kit(project_id, current_user.id, db)
    registered = []
    failed = []
    for handle in data.handles:
        # Simulate registration: mark as unavailable
        if handle.endswith((".app", ".com")):
            registered.append(handle)
            for item in bk.namespace:
                if item.get("handle") == handle:
                    item["available"] = False
        else:
            failed.append(handle)
    await db.commit()
    return {
        "registered": registered,
        "failed": failed,
        "message": "Domains queued for registration"
    }

@router.post("/{project_id}/brand-kit/check-namespace", response_model=NamespaceCheckResponse)
async def check_namespace(
    project_id: str,
    data: NamespaceCheckRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    # Mock check: .app and .com available
    results = {handle: handle.endswith((".app", ".com")) for handle in data.handles}
    return {"results": results}
EOF

# ----------------------------------------------------------------------
# 4. tech_setup.py
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/tech_setup.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.tech_setup import TechSetup, SectionLockStatus
from ....core.exceptions import NotFoundError

router = APIRouter()

async def get_current_version_tech_setup(project_id: str, user_id: str, db: AsyncSession):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    v_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = v_result.scalar_one_or_none()
    if not version:
        raise HTTPException(404, "Version not found")
    ts_result = await db.execute(select(TechSetup).where(TechSetup.version_id == version.id))
    tech_setup = ts_result.scalar_one_or_none()
    if not tech_setup:
        tech_setup = TechSetup(version_id=version.id, online_presence={}, automations={}, store={})
        db.add(tech_setup)
        await db.commit()
        await db.refresh(tech_setup)
    return tech_setup, project

@router.get("/{project_id}/tech-setup")
async def get_tech_setup(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    ts, project = await get_current_version_tech_setup(project_id, current_user.id, db)
    return {
        "project_id": project.public_id,
        "version_id": ts.version_id,
        "lock_status": ts.lock_status.value,
        "online_presence": ts.online_presence,
        "automations": ts.automations,
        "store": ts.store,
        "updated_at": ts.updated_at.isoformat()
    }
EOF

# ----------------------------------------------------------------------
# 5. overview.py (computed on the fly)
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/overview.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.market_research import MarketResearch
from ....models.financials import Financials
from ....models.thread import Thread
from ....core.exceptions import NotFoundError

router = APIRouter()

@router.get("/{project_id}/overview")
async def get_overview(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        return {"error": "No current version"}
    v_result = await db.execute(select(Version).where(Version.id == project.current_version_id))
    version = v_result.scalar_one_or_none()
    if not version:
        return {"error": "Version not found"}
    mr_result = await db.execute(select(MarketResearch).where(MarketResearch.version_id == version.id))
    mr = mr_result.scalar_one_or_none()
    mr_status = "done" if mr and (mr.signals or mr.competitors) else "pending"
    fin_result = await db.execute(select(Financials).where(Financials.version_id == version.id))
    fin = fin_result.scalar_one_or_none()
    fin_status = "done" if fin and fin.cost_breakdown else "pending"
    thread_count = await db.execute(select(func.count(Thread.id)).where(Thread.project_id == project.id, Thread.status == "open"))
    open_threads = thread_count.scalar() or 0
    return {
        "project_id": project.public_id,
        "name": project.name,
        "status": project.status.value,
        "lock_status": project.lock_status.value,
        "completion": 0,
        "sections": {
            "market_research": {"status": mr_status, "lock_status": mr.lock_status.value if mr else "unlocked"},
            "financials": {"status": fin_status, "lock_status": fin.lock_status.value if fin else "unlocked"},
            "brand_kit": {"status": "pending", "lock_status": "unlocked"},
            "tech_setup": {"status": "pending", "lock_status": "unlocked"},
        },
        "open_threads_count": open_threads,
        "updated_at": project.updated_at.isoformat(),
    }
EOF

# ----------------------------------------------------------------------
# 6. section_locking.py (lock/unlock individual sections)
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/section_locking.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version
from ....models.market_research import MarketResearch, SectionLockStatus
from ....models.financials import Financials
from ....models.brand_kit import BrandKit
from ....models.tech_setup import TechSetup
from ....core.exceptions import NotFoundError

router = APIRouter()

SECTION_MODELS = {
    "market_research": MarketResearch,
    "financials": Financials,
    "brand_kit": BrandKit,
    "tech_setup": TechSetup,
}

async def get_section_record(project_id: str, section: str, user_id: str, db: AsyncSession):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    model = SECTION_MODELS.get(section)
    if not model:
        raise HTTPException(400, f"Invalid section: {section}")
    result = await db.execute(select(model).where(model.version_id == project.current_version_id))
    record = result.scalar_one_or_none()
    if not record:
        record = model(version_id=project.current_version_id)
        db.add(record)
        await db.commit()
        await db.refresh(record)
    return record, project

@router.post("/{project_id}/sections/{section}/lock")
async def lock_section(project_id: str, section: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    record, project = await get_section_record(project_id, section, current_user.id, db)
    record.lock_status = SectionLockStatus.LOCKED
    await db.commit()
    return {
        "project_id": project.public_id,
        "section": section,
        "lock_status": "locked",
        "locked_at": record.updated_at.isoformat(),
        "ai_mode_change": "AI will now optimize within this section rather than challenge it"
    }

@router.post("/{project_id}/sections/{section}/unlock")
async def unlock_section(project_id: str, section: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    record, project = await get_section_record(project_id, section, current_user.id, db)
    record.lock_status = SectionLockStatus.UNLOCKED
    await db.commit()
    return {
        "project_id": project.public_id,
        "section": section,
        "lock_status": "unlocked",
        "unlocked_at": record.updated_at.isoformat(),
        "ai_mode_change": "AI will now challenge assumptions in this section again"
    }
EOF

# ----------------------------------------------------------------------
# 7. locking.py (full project lock and lock-readiness)
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/locking.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project, ProjectLockStatus
from ....models.market_research import MarketResearch
from ....models.financials import Financials
from ....models.brand_kit import BrandKit
from ....models.tech_setup import TechSetup
from ....core.exceptions import NotFoundError

router = APIRouter()

@router.get("/{project_id}/lock-readiness")
async def lock_readiness(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    if not project.current_version_id:
        raise HTTPException(404, "No current version")
    sections_status = []
    warnings_count = 0
    for section_name, model in [("market_research", MarketResearch), ("financials", Financials), ("brand_kit", BrandKit), ("tech_setup", TechSetup)]:
        result = await db.execute(select(model).where(model.version_id == project.current_version_id))
        record = result.scalar_one_or_none()
        lock_status = record.lock_status.value if record else "unlocked"
        warning = None
        if lock_status != "locked":
            if section_name == "tech_setup":
                warning = "Still unlocked. Worth reviewing."
            elif section_name == "market_research":
                warning = "Consider locking market research after final review."
            warnings_count += 1
        sections_status.append({
            "section": section_name,
            "lock_status": lock_status,
            "warning": warning
        })
    ready = all(s["lock_status"] == "locked" for s in sections_status)
    return {
        "project_id": project.public_id,
        "ready_to_lock": ready,
        "sections": sections_status,
        "warnings_count": warnings_count,
        "blocking": not ready
    }

@router.post("/{project_id}/lock")
async def lock_project(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    project.lock_status = ProjectLockStatus.LOCKED
    await db.commit()
    # Phase 6 will add Celery task for PDF generation
    return {
        "project_id": project.public_id,
        "lock_status": "locked",
        "locked_at": project.updated_at.isoformat(),
        "section_summary": [],
        "founder_brief_id": None,
        "warnings": 0,
        "founder_brief_status": "generating"
    }
EOF

# ----------------------------------------------------------------------
# 8. versions.py
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/versions.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import Dict, Optional
import uuid
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.version import Version, VersionType
from ....models.market_research import MarketResearch
from ....models.financials import Financials
from ....models.brand_kit import BrandKit
from ....models.tech_setup import TechSetup
from ....core.exceptions import NotFoundError

router = APIRouter()

class BranchRequest(BaseModel):
    label: str

class MergeRequest(BaseModel):
    label: str
    sections: Dict[str, str]  # section -> version_id or branch_id

async def get_project(project_id: str, user_id: str, db: AsyncSession):
    result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == user_id))
    project = result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    return project

@router.get("/{project_id}/versions")
async def list_versions(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    result = await db.execute(select(Version).where(Version.project_id == project.id).order_by(Version.created_at.desc()))
    versions = result.scalars().all()
    data = []
    for v in versions:
        data.append({
            "id": v.public_id,
            "label": v.label,
            "type": v.type.value,
            "number": v.number,
            "is_current": v.id == project.current_version_id,
            "parent_version_id": v.parent_version_id,
            "branch_id": v.branch_id,
            "changes": v.changes,
            "change_tags": [],
            "created_at": v.created_at.isoformat()
        })
    return {
        "project_id": project.public_id,
        "current_version_id": project.current_version_id,
        "versions": data
    }

@router.post("/{project_id}/versions/{version_id}/restore")
async def restore_version(project_id: str, version_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    v_result = await db.execute(select(Version).where(Version.public_id == version_id, Version.project_id == project.id))
    old_version = v_result.scalar_one_or_none()
    if not old_version:
        raise NotFoundError("Version", version_id)
    new_version_id = str(uuid.uuid4())
    new_public_id = f"ver_{uuid.uuid4().hex[:8]}"
    max_num_result = await db.execute(select(Version.number).where(Version.project_id == project.id, Version.type == VersionType.VERSION).order_by(Version.number.desc()).limit(1))
    max_num = max_num_result.scalar() or 0
    new_number = max_num + 1
    new_version = Version(
        id=new_version_id,
        public_id=new_public_id,
        project_id=project.id,
        parent_version_id=old_version.id,
        label=f"Restored from {old_version.label}",
        type=VersionType.VERSION,
        number=new_number,
        changes={"restored_from": old_version.public_id}
    )
    db.add(new_version)
    # Clone section data
    for model in [MarketResearch, Financials, BrandKit, TechSetup]:
        old_rec_result = await db.execute(select(model).where(model.version_id == old_version.id))
        old_rec = old_rec_result.scalar_one_or_none()
        if old_rec:
            new_rec = model(version_id=new_version_id)
            for col in model.__table__.columns:
                if col.name not in ["id", "version_id", "updated_at"]:
                    setattr(new_rec, col.name, getattr(old_rec, col.name))
            db.add(new_rec)
    project.current_version_id = new_version_id
    await db.commit()
    return {
        "project_id": project.public_id,
        "restored_from_version_id": old_version.public_id,
        "new_version_id": new_public_id,
        "message": f"Restored from {old_version.label}. New version created."
    }

@router.post("/{project_id}/versions/{version_id}/branch")
async def create_branch(project_id: str, version_id: str, data: BranchRequest, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    v_result = await db.execute(select(Version).where(Version.public_id == version_id, Version.project_id == project.id))
    base_version = v_result.scalar_one_or_none()
    if not base_version:
        raise NotFoundError("Version", version_id)
    branch_id = f"br_{uuid.uuid4().hex[:8]}"
    new_version = Version(
        id=str(uuid.uuid4()),
        public_id=branch_id,
        project_id=project.id,
        parent_version_id=base_version.id,
        label=data.label,
        type=VersionType.BRANCH,
        number=None,
        branch_id=branch_id,
        changes={}
    )
    db.add(new_version)
    for model in [MarketResearch, Financials, BrandKit, TechSetup]:
        old_rec_result = await db.execute(select(model).where(model.version_id == base_version.id))
        old_rec = old_rec_result.scalar_one_or_none()
        if old_rec:
            new_rec = model(version_id=new_version.id)
            for col in model.__table__.columns:
                if col.name not in ["id", "version_id", "updated_at"]:
                    setattr(new_rec, col.name, getattr(old_rec, col.name))
            db.add(new_rec)
    await db.commit()
    return {
        "branch_id": branch_id,
        "label": data.label,
        "parent_version_id": base_version.public_id,
        "created_at": new_version.created_at.isoformat()
    }

@router.post("/{project_id}/versions/merge")
async def merge_versions(project_id: str, data: MergeRequest, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    new_version_id = str(uuid.uuid4())
    new_public_id = f"ver_{uuid.uuid4().hex[:8]}"
    max_num_result = await db.execute(select(Version.number).where(Version.project_id == project.id, Version.type == VersionType.VERSION).order_by(Version.number.desc()).limit(1))
    max_num = max_num_result.scalar() or 0
    new_version = Version(
        id=new_version_id,
        public_id=new_public_id,
        project_id=project.id,
        label=data.label,
        type=VersionType.VERSION,
        number=max_num + 1,
        changes={"merged_from": data.sections}
    )
    db.add(new_version)
    sources = {}
    for source_public_id in set(data.sections.values()):
        src_result = await db.execute(select(Version).where(Version.public_id == source_public_id, Version.project_id == project.id))
        src = src_result.scalar_one_or_none()
        if src:
            sources[source_public_id] = src.id
    for section, source_public_id in data.sections.items():
        source_version_id = sources.get(source_public_id)
        if not source_version_id:
            continue
        model_map = {
            "market_research": MarketResearch,
            "financials": Financials,
            "brand_kit": BrandKit,
            "tech_setup": TechSetup
        }
        model = model_map.get(section)
        if not model:
            continue
        old_rec_result = await db.execute(select(model).where(model.version_id == source_version_id))
        old_rec = old_rec_result.scalar_one_or_none()
        if old_rec:
            new_rec = model(version_id=new_version.id)
            for col in model.__table__.columns:
                if col.name not in ["id", "version_id", "updated_at"]:
                    setattr(new_rec, col.name, getattr(old_rec, col.name))
            db.add(new_rec)
    project.current_version_id = new_version_id
    await db.commit()
    return {
        "new_version_id": new_public_id,
        "label": data.label,
        "merged_from": data.sections,
        "created_at": new_version.created_at.isoformat()
    }

@router.get("/{project_id}/versions/compare")
async def compare_versions(project_id: str, version_a: str = Query(...), version_b: str = Query(...), current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    project = await get_project(project_id, current_user.id, db)
    v1_result = await db.execute(select(Version).where(Version.public_id == version_a, Version.project_id == project.id))
    v1 = v1_result.scalar_one_or_none()
    v2_result = await db.execute(select(Version).where(Version.public_id == version_b, Version.project_id == project.id))
    v2 = v2_result.scalar_one_or_none()
    if not v1 or not v2:
        raise HTTPException(404, "One or both versions not found")
    fin1 = await db.execute(select(Financials).where(Financials.version_id == v1.id))
    fin1_rec = fin1.scalar_one_or_none()
    fin2 = await db.execute(select(Financials).where(Financials.version_id == v2.id))
    fin2_rec = fin2.scalar_one_or_none()
    diff = {}
    if fin1_rec and fin2_rec:
        diff["financials"] = {
            "version_a": fin1_rec.calculated,
            "version_b": fin2_rec.calculated
        }
    return {
        "version_a": {"id": v1.public_id, "label": v1.label, "badge_color": "blue"},
        "version_b": {"id": v2.public_id, "label": v2.label, "badge_color": "pink"},
        "diff": diff
    }
EOF

# ----------------------------------------------------------------------
# 9. threads.py (ideation threads)
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/threads.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException, Header
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from pydantic import BaseModel
from typing import List, Optional
import uuid
from datetime import datetime
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.thread import Thread, ThreadStatus, Message
from ....models.amendment import Amendment, AmendmentStatus
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
    # Placeholder assistant response (Phase 6 will replace with real agent)
    assistant_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread_id,
        role="assistant",
        content="This is a placeholder response. Agent integration will be added in Phase 6.",
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

@router.get("/threads/{thread_id}")
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

@router.post("/threads/{thread_id}/messages")
async def add_message(thread_id: str, data: MessageCreate, idempotency_key: str = Header(...), current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    t_result = await db.execute(select(Thread).where(Thread.public_id == thread_id))
    thread = t_result.scalar_one_or_none()
    if not thread:
        raise NotFoundError("Thread", thread_id)
    p_result = await db.execute(select(Project).where(Project.id == thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    existing = await db.execute(select(Message).where(Message.thread_id == thread.id, Message.idempotency_key == idempotency_key))
    if existing.scalar_one_or_none():
        # Return existing conversation
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
    # Placeholder assistant response (Phase 6 will replace)
    assistant_msg = Message(
        id=str(uuid.uuid4()),
        thread_id=thread.id,
        role="assistant",
        content=f"Echo: {data.content[:100]} (Agent response will be implemented in Phase 6)",
        idempotency_key=str(uuid.uuid4())
    )
    db.add(assistant_msg)
    thread.updated_at = datetime.utcnow()
    await db.commit()
    return {
        "user_message": {"id": user_msg.id, "role": "user", "content": user_msg.content, "created_at": user_msg.created_at.isoformat()},
        "assistant_message": {"id": assistant_msg.id, "role": "assistant", "content": assistant_msg.content, "created_at": assistant_msg.created_at.isoformat()}
    }

@router.post("/threads/{thread_id}/promote")
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

@router.delete("/threads/{thread_id}")
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
EOF

# ----------------------------------------------------------------------
# 10. refinements.py
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/refinements.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import Optional
import uuid
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.refinement import Refinement, RefinementStatus
from ....core.exceptions import NotFoundError

router = APIRouter()

class RefineRequest(BaseModel):
    target_element: str
    target_id: Optional[str] = None
    instruction: str

class RefinementModify(BaseModel):
    modified_after: str

@router.post("/{project_id}/sections/{section}/refine")
async def create_refinement(
    project_id: str,
    section: str,
    data: RefineRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db)
):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    refinement_id = str(uuid.uuid4())
    public_id = f"ref_{uuid.uuid4().hex[:8]}"
    refinement = Refinement(
        id=refinement_id,
        public_id=public_id,
        project_id=project.id,
        target_section=section,
        target_element=data.target_element,
        target_id=data.target_id,
        instruction=data.instruction,
        diff_before="Original content placeholder",
        diff_after="Modified content placeholder",
        ripple_preview={"affected_sections": ["overview"]},
        status=RefinementStatus.PENDING
    )
    db.add(refinement)
    await db.commit()
    return {
        "refinement_id": public_id,
        "target_section": section,
        "target_element": data.target_element,
        "target_id": data.target_id,
        "diff": {
            "before": refinement.diff_before,
            "after": refinement.diff_after
        },
        "ripple_preview": refinement.ripple_preview,
        "status": "pending_review"
    }

@router.post("/refinements/{refinement_id}/accept")
async def accept_refinement(refinement_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(Refinement).where(Refinement.public_id == refinement_id))
    refinement = r_result.scalar_one_or_none()
    if not refinement:
        raise NotFoundError("Refinement", refinement_id)
    p_result = await db.execute(select(Project).where(Project.id == refinement.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    refinement.status = RefinementStatus.ACCEPTED
    await db.commit()
    return {
        "refinement_id": refinement.public_id,
        "status": "accepted",
        "sections_updated": [refinement.target_section],
        "new_version_id": "ver_placeholder",
        "message": "Refinement accepted. Version created."
    }

@router.post("/refinements/{refinement_id}/reject")
async def reject_refinement(refinement_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(Refinement).where(Refinement.public_id == refinement_id))
    refinement = r_result.scalar_one_or_none()
    if not refinement:
        raise NotFoundError("Refinement", refinement_id)
    p_result = await db.execute(select(Project).where(Project.id == refinement.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    refinement.status = RefinementStatus.REJECTED
    await db.commit()
    return {"refinement_id": refinement.public_id, "status": "rejected"}

@router.patch("/refinements/{refinement_id}")
async def modify_refinement(refinement_id: str, data: RefinementModify, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(Refinement).where(Refinement.public_id == refinement_id))
    refinement = r_result.scalar_one_or_none()
    if not refinement:
        raise NotFoundError("Refinement", refinement_id)
    p_result = await db.execute(select(Project).where(Project.id == refinement.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    refinement.diff_after = data.modified_after
    await db.commit()
    return {
        "refinement_id": refinement.public_id,
        "diff": {
            "before": refinement.diff_before,
            "after": refinement.diff_after
        },
        "status": "pending_review"
    }
EOF

# ----------------------------------------------------------------------
# 11. proactive_threads.py
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/proactive_threads.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from datetime import datetime, timedelta
import uuid
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.proactive_thread import ProactiveThread, ProactiveStatus
from ....core.exceptions import NotFoundError

router = APIRouter()

class SnoozeRequest(BaseModel):
    snooze_hours: int

@router.get("/{project_id}/proactive-threads")
async def list_proactive_threads(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    result = await db.execute(select(ProactiveThread).where(ProactiveThread.project_id == project.id, ProactiveThread.status.in_([ProactiveStatus.OPEN, ProactiveStatus.SNOOZED])).order_by(ProactiveThread.created_at.desc()))
    threads = result.scalars().all()
    data = []
    for t in threads:
        data.append({
            "id": t.public_id,
            "question": t.question,
            "source_section": t.source_section,
            "source_detail": t.source_detail,
            "bullet_color": t.bullet_color,
            "status": t.status.value,
            "created_at": t.created_at.isoformat()
        })
    return {"project_id": project.public_id, "threads": data, "total": len(data)}

@router.post("/proactive-threads/{pthr_id}/explore", status_code=201)
async def explore_proactive_thread(pthr_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(ProactiveThread).where(ProactiveThread.public_id == pthr_id))
    p_thread = r_result.scalar_one_or_none()
    if not p_thread:
        raise NotFoundError("Proactive thread", pthr_id)
    p_result = await db.execute(select(Project).where(Project.id == p_thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    # Convert to ideation thread (simplified)
    from ....models.thread import Thread, ThreadStatus
    thread_id = str(uuid.uuid4())
    public_id = f"thr_{uuid.uuid4().hex[:8]}"
    new_thread = Thread(
        id=thread_id,
        public_id=public_id,
        project_id=p_thread.project_id,
        name=p_thread.question[:50],
        context_section=p_thread.source_section,
        context_detail=p_thread.source_detail,
        status=ThreadStatus.OPEN,
    )
    db.add(new_thread)
    p_thread.status = ProactiveStatus.DISMISSED
    await db.commit()
    return {
        "ideation_thread_id": public_id,
        "name": p_thread.question[:50],
        "context_section": p_thread.source_section,
        "context_detail": p_thread.source_detail,
        "opening_message": p_thread.question,
        "redirect_to": f"/projects/{p_thread.project_id}/threads/{public_id}"
    }

@router.post("/proactive-threads/{pthr_id}/dismiss")
async def dismiss_proactive_thread(pthr_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(ProactiveThread).where(ProactiveThread.public_id == pthr_id))
    p_thread = r_result.scalar_one_or_none()
    if not p_thread:
        raise NotFoundError("Proactive thread", pthr_id)
    p_result = await db.execute(select(Project).where(Project.id == p_thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    p_thread.status = ProactiveStatus.DISMISSED
    await db.commit()
    return {"id": pthr_id, "status": "dismissed"}

@router.post("/proactive-threads/{pthr_id}/snooze")
async def snooze_proactive_thread(pthr_id: str, data: SnoozeRequest, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    r_result = await db.execute(select(ProactiveThread).where(ProactiveThread.public_id == pthr_id))
    p_thread = r_result.scalar_one_or_none()
    if not p_thread:
        raise NotFoundError("Proactive thread", pthr_id)
    p_result = await db.execute(select(Project).where(Project.id == p_thread.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    p_thread.status = ProactiveStatus.SNOOZED
    p_thread.snooze_until = datetime.utcnow() + timedelta(hours=data.snooze_hours)
    await db.commit()
    return {"id": pthr_id, "status": "snoozed", "snooze_until": p_thread.snooze_until.isoformat()}
EOF

# ----------------------------------------------------------------------
# 12. amendments.py
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/amendments.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import Optional
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....models.amendment import Amendment, AmendmentStatus
from ....core.exceptions import NotFoundError

router = APIRouter()

class AmendmentModify(BaseModel):
    summary: Optional[str] = None
    target_section: Optional[str] = None

@router.get("/{project_id}/amendments")
async def list_amendments(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    result = await db.execute(select(Amendment).where(Amendment.project_id == project.id).order_by(Amendment.created_at.desc()))
    amendments = result.scalars().all()
    data = []
    for a in amendments:
        data.append({
            "id": a.public_id,
            "source": a.source_type,
            "source_id": a.source_id,
            "target_section": a.target_section,
            "summary": a.summary,
            "status": a.status.value,
            "created_at": a.created_at.isoformat()
        })
    return {"project_id": project.public_id, "amendments": data}

@router.post("/amendments/{amendment_id}/accept")
async def accept_amendment(amendment_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    a_result = await db.execute(select(Amendment).where(Amendment.public_id == amendment_id))
    amendment = a_result.scalar_one_or_none()
    if not amendment:
        raise NotFoundError("Amendment", amendment_id)
    p_result = await db.execute(select(Project).where(Project.id == amendment.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    amendment.status = AmendmentStatus.ACCEPTED
    await db.commit()
    return {
        "amendment_id": amendment.public_id,
        "status": "accepted",
        "sections_updated": [amendment.target_section],
        "new_version_id": "ver_placeholder",
        "message": "Amendment accepted. New version created."
    }

@router.post("/amendments/{amendment_id}/reject")
async def reject_amendment(amendment_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    a_result = await db.execute(select(Amendment).where(Amendment.public_id == amendment_id))
    amendment = a_result.scalar_one_or_none()
    if not amendment:
        raise NotFoundError("Amendment", amendment_id)
    p_result = await db.execute(select(Project).where(Project.id == amendment.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    amendment.status = AmendmentStatus.REJECTED
    await db.commit()
    return {"amendment_id": amendment.public_id, "status": "rejected"}

@router.patch("/amendments/{amendment_id}")
async def modify_amendment(amendment_id: str, data: AmendmentModify, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    a_result = await db.execute(select(Amendment).where(Amendment.public_id == amendment_id))
    amendment = a_result.scalar_one_or_none()
    if not amendment:
        raise NotFoundError("Amendment", amendment_id)
    p_result = await db.execute(select(Project).where(Project.id == amendment.project_id, Project.owner_id == current_user.id))
    if not p_result.scalar_one_or_none():
        raise HTTPException(403, "Forbidden")
    if data.summary is not None:
        amendment.summary = data.summary
    if data.target_section is not None:
        amendment.target_section = data.target_section
    await db.commit()
    return {
        "amendment_id": amendment.public_id,
        "summary": amendment.summary,
        "target_section": amendment.target_section,
        "status": amendment.status.value
    }
EOF

# ----------------------------------------------------------------------
# 13. founder_brief.py (status and export placeholder)
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/endpoints/founder_brief.py << 'EOF'
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from ....core.database import get_db
from ....api.dependencies import get_current_user
from ....models.user import User
from ....models.project import Project
from ....core.exceptions import NotFoundError

router = APIRouter()

@router.get("/{project_id}/founder-brief")
async def get_founder_brief_status(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    # Phase 6 will implement real PDF generation
    return {"status": "generating"}

@router.get("/{project_id}/founder-brief/export")
async def export_founder_brief(project_id: str, current_user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    p_result = await db.execute(select(Project).where(Project.public_id == project_id, Project.owner_id == current_user.id))
    project = p_result.scalar_one_or_none()
    if not project:
        raise NotFoundError("Project", project_id)
    raise HTTPException(404, "PDF not yet generated")
EOF

# ----------------------------------------------------------------------
# 14. Update api/v1/__init__.py to include all new routers
# ----------------------------------------------------------------------
cat > src/launchmate/api/v1/__init__.py << 'EOF'
from fastapi import APIRouter
from .endpoints import auth, users, projects
from .endpoints import market_research, financials, brand_kit, tech_setup, overview
from .endpoints import section_locking, locking
from .endpoints import versions
from .endpoints import threads, refinements, proactive_threads, amendments
from .endpoints import founder_brief

router = APIRouter(prefix="/api/v1")
router.include_router(auth.router, prefix="/auth", tags=["auth"])
router.include_router(users.router, prefix="/users", tags=["users"])
router.include_router(projects.router, prefix="/projects", tags=["projects"])
router.include_router(market_research.router, prefix="/projects", tags=["market_research"])
router.include_router(financials.router, prefix="/projects", tags=["financials"])
router.include_router(brand_kit.router, prefix="/projects", tags=["brand_kit"])
router.include_router(tech_setup.router, prefix="/projects", tags=["tech_setup"])
router.include_router(overview.router, prefix="/projects", tags=["overview"])
router.include_router(section_locking.router, prefix="/projects", tags=["section_locking"])
router.include_router(locking.router, prefix="/projects", tags=["locking"])
router.include_router(versions.router, prefix="/projects", tags=["versions"])
router.include_router(threads.router, prefix="/projects", tags=["threads"])
router.include_router(refinements.router, prefix="/projects", tags=["refinements"])
router.include_router(proactive_threads.router, prefix="/projects", tags=["proactive_threads"])
router.include_router(amendments.router, prefix="/projects", tags=["amendments"])
router.include_router(founder_brief.router, prefix="/projects", tags=["founder_brief"])
EOF

echo "✅ Phase 5 complete. Restart the backend and test endpoints."
echo "   Example: curl http://localhost:8000/api/v1/projects/{project_id}/market-research -H 'Authorization: Bearer $TOKEN'"
echo "   Also test threads, refinements, versions, etc."