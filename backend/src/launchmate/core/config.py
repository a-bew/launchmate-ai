from pydantic_settings import BaseSettings
from pydantic import Field
from typing import Optional

class Settings(BaseSettings):
    # Database
    DATABASE_URL: str = "postgresql+asyncpg://launchmate:launchmate@db:5432/launchmate"
    
    # Redis
    REDIS_URL: str = "redis://redis:6379/0"
    
    # JWT
    SECRET_KEY: str = Field(..., min_length=32)
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    
    # Bright Data
    BRIGHTDATA_API_KEY: str = ""
    SERP_ZONE: str = "serp_api2"
    UNLOCKER_ZONE: str = "web_unlocker1"
    
    # LLM
    OPENROUTER_API_KEY: str = ""
    LLM_MODEL: str = "step-3.5-flash"
    
    # Celery (default to Redis)
    CELERY_BROKER_URL: Optional[str] = None
    CELERY_RESULT_BACKEND: Optional[str] = None
    
    # PDF Storage
    STORAGE_BACKEND: str = "local"  # local or s3
    AWS_BUCKET: str = ""
    AWS_ACCESS_KEY_ID: str = ""
    AWS_SECRET_ACCESS_KEY: str = ""
    AWS_REGION: str = "us-east-1"
    AWS_ENDPOINT_URL: str = ""   # <-- new field
    
    class Config:
        env_file = ".env"
        extra = "ignore"

settings = Settings()
