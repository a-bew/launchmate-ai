from celery import Celery
from .config import settings

celery_app = Celery(
    "launchmate",
    broker=settings.CELERY_BROKER_URL or settings.REDIS_URL,
    backend=settings.CELERY_RESULT_BACKEND or settings.REDIS_URL,
    include=[
        "launchmate.tasks.generation_tasks",
        "launchmate.tasks.proactive_tasks",
        "launchmate.tasks.pdf_tasks",
        "launchmate.tasks.domain_tasks",
        "launchmate.tasks.email_tasks"
    ]
)

celery_app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="UTC",
    enable_utc=True,
    task_track_started=True,
    task_time_limit=30 * 60,
    task_soft_time_limit=25 * 60,
    beat_schedule={
        "generate_proactive_threads_daily": {
            "task": "launchmate.tasks.proactive_tasks.generate_proactive_threads",
            "schedule": 86400,  # 24 hours
            "args": (),
        },
    },
)
