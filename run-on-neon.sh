#!/usr/bin/env bash
# Run the same suite against a throwaway Neon branch.
#
# A branch is a copy-on-write copy of the parent, so the roles and tables this
# creates cannot reach anything else, and the branch is deleted on the way out
# whether the suite passed or not.
#
# Pass `verify` to run the mutation script against the branch instead of the
# suite.
#
# Needs NEON_API_KEY and NEON_PROJECT_ID.
set -euo pipefail
cd "$(dirname "$0")"

: "${NEON_API_KEY:?set NEON_API_KEY}"
: "${NEON_PROJECT_ID:?set NEON_PROJECT_ID}"

echo "==> installing test dependencies"
python3 -m venv .venv >/dev/null
./.venv/bin/pip install -q -r requirements.txt

BRANCH="rls-test-$(date +%s)"
echo "==> creating branch $BRANCH"
ENV_FILE="$(mktemp)"
chmod 600 "$ENV_FILE"
./.venv/bin/python neon/branch.py create "$NEON_PROJECT_ID" "$BRANCH" > "$ENV_FILE"

cleanup() {
  if [ -n "${NEON_BRANCH_ID:-}" ]; then
    echo "==> deleting branch $NEON_BRANCH_ID"
    ./.venv/bin/python neon/branch.py delete "$NEON_PROJECT_ID" "$NEON_BRANCH_ID" || true
  fi
  rm -f "$ENV_FILE"
}
trap cleanup EXIT

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

echo "==> applying schema and seed"
./.venv/bin/python neon/apply.py neon/reset.sql sql/01-schema.sql sql/02-seed.sql

if [ "${1:-}" = "verify" ]; then
  echo "==> breaking the schema to check the suite notices"
  ./verify-suite.sh
else
  echo "==> running the suite"
  ./.venv/bin/python -m pytest tests -v
fi
