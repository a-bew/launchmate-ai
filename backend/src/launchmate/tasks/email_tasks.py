import logging
from celery import shared_task

logger = logging.getLogger(__name__)

@shared_task
def send_email(to: str, subject: str, body: str):
    logger.info(f"Email would be sent to {to} with subject '{subject}':\n{body}")
    # In production, configure SMTP
    return {"status": "sent", "to": to, "subject": subject}
