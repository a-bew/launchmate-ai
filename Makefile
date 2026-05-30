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
