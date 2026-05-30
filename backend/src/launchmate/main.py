from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from .api.v1 import router as api_router
from .core.database import engine, Base
from .core.config import settings

app = FastAPI(title="LaunchMate API", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
async def startup():
    # Create tables if they don't exist (for development)
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

app.include_router(api_router)

@app.get("/health")
async def health():
    return {"status": "ok"}
