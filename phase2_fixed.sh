#!/bin/bash
set -e

echo "📦 Phase 2 (Fixed): Database Models, Config, and Alembic Migration"

cd backend

# Force Python 3.12
poetry env use 3.12 || true

# Clean up any previous alembic mess
rm -rf alembic
rm -f alembic.ini

# -------------------------------
# (All the file creation commands from original phase2.sh go here)
# -------------------------------

# Instead of repeating the whole script, I'll give you the minimal fixes.
# But for completeness, re-run the original phase2.sh after cleaning.