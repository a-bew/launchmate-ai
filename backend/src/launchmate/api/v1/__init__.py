from fastapi import APIRouter
from .endpoints import auth, users, projects, generation
from .endpoints import market_research, financials, brand_kit, tech_setup, overview
from .endpoints import section_locking, locking
from .endpoints import versions
from .endpoints import threads, refinements, proactive_threads, amendments
from .endpoints import founder_brief

router = APIRouter(prefix="/api/v1")
router.include_router(auth.router, prefix="/auth", tags=["auth"])
router.include_router(users.router, prefix="/users", tags=["users"])
router.include_router(projects.router, prefix="/projects", tags=["projects"])
router.include_router(generation.router, prefix="/projects", tags=["generation"])
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
