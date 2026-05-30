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




curl -X POST http://localhost:8000/api/v1/auth/register   -H "Content-Type: application/json"   -d '{"name":"Test User","email":"test@example.com","password":"secret"}'
{"user":{"id":"usr_0b722f0e","name":"Test User","email":"test@example.com","role":"Builder","avatar_initials":"TU","created_at":"2026-05-30T16:40:01.245608+00:00"},"token":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIzNWM4MzdlMC1lZTc0LTQ2N2EtOWE3YS0wNzRjOTVjN2E4YjkiLCJleHAiOjE3ODAxNjEwMDF9.QL2fnYSvdN-2gGq_tTOqMCf4zTgaNqOJIBI1hpDZYLo"}

curl -X POST http://localhost:8000/api/v1/auth/login \              curl -X POST http://localhost:8000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"secret"}'
{"user":{"id":"usr_0b722f0e","name":"Test User","email":"test@example.com","role":"Builder","avatar_initials":"TU","created_at":"2026-05-30T16:40:01.245608+00:00"},"token":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIzNWM4MzdlMC1lZTc0LTQ2N2EtOWE3YS0wNzRjOTVjN2E4YjkiLCJleHAiOjE3ODAxNjExNDl9.2ICIAI7ao6OOhnTuEtQ4ucBS7zCzyFPuoikO9XdSbas"}


TOKEN="eyJhbGcieyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIzNWM4MzdlMC1lZTc0LTQ2N2EtOWE3YS0wNzRjOTVjN2E4YjkiLCJleHAiOjE3ODAxNjExNDl9.2ICIAI7ao6OOhnTuEtQ4ucBS7zCzyFPuoikO9XdSbas"

curl -X POST http://localhost:8000/api/v1/projects \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"core_premise":"AI SaaS","primary_market":"Global","initial_budget":10000,"budget_label":"$10k","market_vectors":["AI","B2B"]}'

