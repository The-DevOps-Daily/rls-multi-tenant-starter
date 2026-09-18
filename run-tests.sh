#!/usr/bin/env bash
# Bring up a throwaway Postgres, apply the schema, run the suite, tear it down.
set -euo pipefail
cd "$(dirname "$0")"

cleanup() { docker compose down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> starting postgres"
docker compose up -d --wait

echo "==> installing test dependencies"
python3 -m venv .venv >/dev/null
./.venv/bin/pip install -q -r requirements.txt

echo "==> running the suite"
./.venv/bin/python -m pytest tests -v
