#!/usr/bin/env bash
# Prove the test suite is worth having.
#
# A passing isolation suite is weak evidence on its own. So this breaks the
# schema on purpose, five ways, and asserts that the suite notices each one.
#
# It exits non-zero if any mutation goes undetected, which is the point: a
# script that only printed results would itself be the thing nobody checked.
#
# Standalone: brings the database up if it is not already running, which it
# will not be after run-tests.sh, because that tears its own down.
set -uo pipefail
cd "$(dirname "$0")"

# Two ways to reach the database. run-on-neon.sh exports NEON_OWNER_URL, in
# which case the branch it made is already up and Docker is not involved.
started_db=0
if [ -z "${NEON_OWNER_URL:-}" ]; then
  if ! docker compose ps --status running --quiet db >/dev/null 2>&1 || \
     [ -z "$(docker compose ps --status running --quiet db 2>/dev/null)" ]; then
    echo "==> starting postgres"
    docker compose up -d --wait >/dev/null
    started_db=1
  fi
fi

if [ ! -x ./.venv/bin/python ]; then
  echo "==> installing test dependencies"
  python3 -m venv .venv >/dev/null
  ./.venv/bin/pip install -q -r requirements.txt
fi

PY=./.venv/bin/python
failures=0

sql() {
  if [ -n "${NEON_OWNER_URL:-}" ]; then
    if ! $PY neon/exec.py "$1" >/dev/null 2>&1; then
      echo "  ! could not apply: ${1:0:60}..."
      failures=$((failures + 1))
    fi
    return
  fi
  if ! docker compose exec -T db psql -U postgres -d rlsdemo -Atq -v ON_ERROR_STOP=1 -c "$1" >/dev/null 2>&1; then
    echo "  ! could not apply: ${1:0:60}..."
    failures=$((failures + 1))
  fi
}

restore() {
  sql "DELETE FROM documents WHERE title = 'planted'"
  sql "ALTER TABLE documents ENABLE ROW LEVEL SECURITY"
  sql "ALTER TABLE documents FORCE ROW LEVEL SECURITY"
  sql "ALTER TABLE tenants   ENABLE ROW LEVEL SECURITY"
  sql "ALTER TABLE tenants   FORCE ROW LEVEL SECURITY"
  sql "DROP POLICY IF EXISTS documents_tenant_isolation ON documents"
  sql "CREATE POLICY documents_tenant_isolation ON documents
         USING (tenant_id = current_tenant())
         WITH CHECK (tenant_id = current_tenant())"
}
finish() {
  restore
  if [ "$started_db" -eq 1 ]; then docker compose down -v >/dev/null 2>&1; fi
  return 0
}
trap finish EXIT

# Runs the suite and asserts the outcome. `expect` is pass or fail.
check() {
  local label=$1 expect=$2
  local out rc
  out=$($PY -m pytest tests -q 2>&1 | tail -1)
  rc=$?
  case "$expect" in
    pass) if [ "$rc" -eq 0 ]; then printf '  ok    %-42s %s\n' "$label" "$out"
          else printf '  FAIL  %-42s %s\n' "$label" "$out"; failures=$((failures + 1)); fi ;;
    fail) if [ "$rc" -ne 0 ]; then printf '  ok    %-42s %s\n' "$label" "$out"
          else printf '  FAIL  %-42s %s   <- mutation went undetected\n' "$label" "$out"
               failures=$((failures + 1)); fi ;;
  esac
}

echo "expecting the suite to pass unmodified, and to fail for every mutation:"
check "baseline" pass

sql "ALTER TABLE documents DISABLE ROW LEVEL SECURITY"
check "RLS disabled on documents" fail
restore

sql "ALTER TABLE tenants DISABLE ROW LEVEL SECURITY"
check "RLS disabled on tenants" fail
restore

sql "ALTER TABLE documents NO FORCE ROW LEVEL SECURITY"
check "FORCE removed, owner exempt again" fail
restore

sql "DROP POLICY documents_tenant_isolation ON documents"
sql "CREATE POLICY documents_tenant_isolation ON documents
       USING (tenant_id = current_tenant()) WITH CHECK (true)"
check "WITH CHECK weakened to true" fail
restore

sql "DROP POLICY documents_tenant_isolation ON documents"
sql "CREATE POLICY documents_tenant_isolation ON documents USING (true)"
check "policy weakened to USING (true)" fail
restore

check "restored" pass

echo
if [ "$failures" -eq 0 ]; then
  echo "every mutation was caught."
else
  echo "$failures problem(s): the suite does not catch everything it claims to."
fi
exit "$failures"
