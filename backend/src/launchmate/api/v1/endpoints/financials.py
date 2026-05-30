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
