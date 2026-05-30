#!/bin/bash
set -e

echo "🚀 LaunchMate Phase 1: Project Scaffolding (5 services)"

# Create directories
mkdir -p backend/src/launchmate backend/alembic/versions backend/scripts
mkdir -p frontend/src
mkdir -p scripts
mkdir -p storage/briefs

# -------------------------------
# backend/pyproject.toml (same as before, but ensure Celery dependencies are included)
# -------------------------------
cat > backend/pyproject.toml << 'EOF'
[tool.poetry]
name = "launchmate-backend"
version = "0.1.0"
description = "AI-powered venture studio assistant"
authors = ["LaunchMate Team"]
readme = "README.md"
package-mode = false

[tool.poetry.dependencies]
python = "^3.12"
fastapi = "^0.115.0"
uvicorn = {extras = ["standard"], version = "^0.30.0"}
pydantic = "^2.9.0"
pydantic-settings = "^2.4.0"
sqlalchemy = "^2.0.35"
asyncpg = "^0.29.0"
alembic = "^1.13.0"
python-jose = {extras = ["cryptography"], version = "^3.3.0"}
passlib = {extras = ["bcrypt"], version = "^1.7.4"}
python-multipart = "^0.0.9"
redis = "^5.0.0"
celery = "^5.4.0"
httpx = "^0.27.0"
langchain = "^0.3.0"
langchain-openai = "^0.2.0"
beautifulsoup4 = "^4.12.0"
requests = "^2.32.0"
python-dotenv = "^1.0.0"
fastapi-cache2 = "^0.2.1"
structlog = "^24.4.0"

[tool.poetry.group.dev.dependencies]
pytest = "^8.3.0"
pytest-asyncio = "^0.24.0"
pytest-cov = "^6.0.0"
httpx = "^0.27.0"
ruff = "^0.6.0"
mypy = "^1.11.0"
pre-commit = "^3.8.0"

[build-system]
requires = ["poetry-core"]
build-backend = "poetry.core.masonry.api"
EOF

# -------------------------------
# backend/Dockerfile (same)
# -------------------------------
cat > backend/Dockerfile << 'EOF'
FROM python:3.12-slim

WORKDIR /app

RUN pip install poetry

COPY pyproject.toml poetry.lock* ./
RUN poetry config virtualenvs.create false \
    && poetry install --no-interaction --no-ansi --no-root

COPY . .

ENV PYTHONPATH=/app/src
ENV PYTHONUNBUFFERED=1

EXPOSE 8000

CMD ["uvicorn", "launchmate.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
EOF

# -------------------------------
# docker-compose.yml (with 5 core services)
# -------------------------------
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  db:
    image: postgres:15-alpine
    environment:
      POSTGRES_USER: launchmate
      POSTGRES_PASSWORD: launchmate
      POSTGRES_DB: launchmate
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U launchmate"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  backend:
    build: ./backend
    ports:
      - "8000:8000"
    volumes:
      - ./backend:/app
      - ./storage:/app/storage
    env_file:
      - ./backend/.env
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql+asyncpg://launchmate:launchmate@db:5432/launchmate
      REDIS_URL: redis://redis:6379/0
    command: uvicorn launchmate.main:app --host 0.0.0.0 --port 8000 --reload

  celery_worker:
    build: ./backend
    volumes:
      - ./backend:/app
      - ./storage:/app/storage
    env_file:
      - ./backend/.env
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql+asyncpg://launchmate:launchmate@db:5432/launchmate
      REDIS_URL: redis://redis:6379/0
    command: celery -A launchmate.core.celery_app worker --loglevel=info

  celery_beat:
    build: ./backend
    volumes:
      - ./backend:/app
    env_file:
      - ./backend/.env
    depends_on:
      - redis
      - db
    environment:
      DATABASE_URL: postgresql+asyncpg://launchmate:launchmate@db:5432/launchmate
      REDIS_URL: redis://redis:6379/0
    command: celery -A launchmate.core.celery_app beat --loglevel=info

  # Optional pgAdmin for development (uncomment if needed)
  # pgadmin:
  #   image: dpage/pgadmin4
  #   environment:
  #     PGADMIN_DEFAULT_EMAIL: admin@launchmate.com
  #     PGADMIN_DEFAULT_PASSWORD: admin
  #   ports:
  #     - "5050:80"
  #   depends_on:
  #     - db

volumes:
  postgres_data:
EOF

# -------------------------------
# backend/.env.example (unchanged)
# -------------------------------
cat > backend/.env.example << 'EOF'
# Database
DATABASE_URL=postgresql+asyncpg://launchmate:launchmate@db:5432/launchmate

# Redis
REDIS_URL=redis://redis:6379/0

# JWT
SECRET_KEY=change-this-in-production
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30

# Bright Data
BRIGHTDATA_API_KEY=your-key
SERP_ZONE=serp_api2
UNLOCKER_ZONE=web_unlocker1

# LLM (OpenRouter)
OPENROUTER_API_KEY=your-key
LLM_MODEL=step-3.5-flash

# Celery (optional, defaults to REDIS_URL)
CELERY_BROKER_URL=
CELERY_RESULT_BACKEND=

# PDF storage
STORAGE_BACKEND=local
AWS_BUCKET=
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_REGION=us-east-1
EOF

# -------------------------------
# Makefile (add celery commands)
# -------------------------------
cat > Makefile << 'EOF'
.PHONY: help install migrate test lint run docker-up docker-down clean celery-worker celery-beat

help:
	@echo "Available commands:"
	@echo "  install        Install dependencies"
	@echo "  migrate        Run Alembic migrations"
	@echo "  test           Run pytest"
	@echo "  lint           Run ruff + mypy"
	@echo "  run            Run FastAPI dev server locally (outside Docker)"
	@echo "  docker-up      Start all services with Docker Compose"
	@echo "  docker-down    Stop all services"
	@echo "  celery-worker  Run Celery worker locally"
	@echo "  celery-beat    Run Celery Beat locally"
	@echo "  clean          Remove venv, cache, and Docker volumes"

install:
	cd backend && poetry install

migrate:
	cd backend && poetry run alembic upgrade head

test:
	cd backend && poetry run pytest --cov=src/launchmate

lint:
	cd backend && poetry run ruff check src/launchmate
	cd backend && poetry run mypy src/launchmate --ignore-missing-imports

run:
	cd backend && poetry run uvicorn launchmate.main:app --reload

celery-worker:
	cd backend && poetry run celery -A launchmate.core.celery_app worker --loglevel=info

celery-beat:
	cd backend && poetry run celery -A launchmate.core.celery_app beat --loglevel=info

docker-up:
	docker-compose up -d --build

docker-down:
	docker-compose down -v

clean:
	rm -rf backend/.venv backend/.pytest_cache backend/.mypy_cache
	rm -rf frontend/node_modules
	docker-compose down -v
EOF

# -------------------------------
# README.md (with escaped backticks)
# -------------------------------
cat > README.md << 'EOF'
# LaunchMate

AI‑powered venture studio assistant.

## Prerequisites

- Python 3.12
- Docker & Docker Compose
- Node.js 18+ (for frontend)
- Poetry (install via `pip install poetry`)

## Quick Start

\`\`\`bash
# Copy environment file
cp backend/.env.example backend/.env
# Edit .env with your keys

# Start all five services
make docker-up
\`\`\`

The API will be available at http://localhost:8000/api/v1  
Auto‑generated docs: http://localhost:8000/docs

## Development

Run locally (outside Docker):

\`\`\`bash
make install   # install dependencies
make migrate   # run database migrations
make run       # start FastAPI with hot reload
\`\`\`

Run Celery locally:

\`\`\`bash
make celery-worker   # worker
make celery-beat     # scheduler (run in another terminal)
\`\`\`

## Environment Variables

See `backend/.env.example` for all required variables.

## License

Proprietary – LaunchMate Inc.
EOF

# -------------------------------
# Placeholder main.py (so backend starts)
# -------------------------------
cat > backend/src/launchmate/main.py << 'EOF'
from fastapi import FastAPI

app = FastAPI(title="LaunchMate", version="0.1.0")

@app.get("/health")
async def health():
    return {"status": "ok"}
EOF

# Empty __init__.py
touch backend/src/launchmate/__init__.py

echo "✅ Phase 1 complete. Now run:"
echo "   cd backend && poetry install"
echo "   cp backend/.env.example backend/.env"
echo "   make docker-up"
echo ""
echo "Verification: 'docker ps' should show 5 containers running (db, redis, backend, celery_worker, celery_beat)."