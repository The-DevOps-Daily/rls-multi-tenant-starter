#!/usr/bin/env bash
# Prove the test suite is worth having.
#
# A passing isolation suite is weak evidence on its own. So this breaks the
# schema on purpose, five ways, and asserts that the suite notices each one.
#
# It exits non-zero if any mutation goes undetected, which is the point: a
# script that only printed results would itself be the thing nobody checked.
#
# Run it after run-tests.sh, against the same running database.
set -uo pipefail
cd "$(dirname "$0")"

PSQL=(docker compose exec -T db psql -U postgres -d rlsdemo -Atq -v ON_ERROR_STOP=1)
PY=./.venv/bin/python
failures=0

sql() {
  if ! "${PSQL[@]}" -c "$1" >/dev/null 2>&1; then
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
trap restore EXIT

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
