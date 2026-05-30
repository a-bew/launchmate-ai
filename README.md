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
# launchmate-ai
