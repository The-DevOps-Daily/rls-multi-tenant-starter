#!/usr/bin/env bash
# Prove the test suite is worth having.
#
# A passing isolation suite means nothing on its own: a suite that queries an
# empty table, or connects as a superuser, passes just as cheerfully against a
# table with no policies at all. So this breaks the schema on purpose, four
# ways, and checks the suite notices each one.
#
# Run it after run-tests.sh, against the same running database.
set -uo pipefail
cd "$(dirname "$0")"

PSQL=(docker compose exec -T db psql -U postgres -d rlsdemo -Atq)
PY=./.venv/bin/python

run() { $PY -m pytest tests -q 2>&1 | tail -1; }
sql() { "${PSQL[@]}" -c "$1" >/dev/null 2>&1; }

restore() {
  sql "DELETE FROM documents WHERE title = 'planted'"
  sql "ALTER TABLE documents ENABLE ROW LEVEL SECURITY"
  sql "ALTER TABLE documents FORCE ROW LEVEL SECURITY"
  sql "DROP POLICY IF EXISTS documents_tenant_isolation ON documents"
  sql "CREATE POLICY documents_tenant_isolation ON documents
         USING (tenant_id = current_tenant())
         WITH CHECK (tenant_id = current_tenant())"
}
trap restore EXIT

echo "baseline                                  $(run)"

sql "ALTER TABLE documents DISABLE ROW LEVEL SECURITY"
echo "RLS disabled entirely                     $(run)"
restore

sql "ALTER TABLE documents NO FORCE ROW LEVEL SECURITY"
echo "FORCE removed (owner exempt again)        $(run)"
restore

sql "DROP POLICY documents_tenant_isolation ON documents"
sql "CREATE POLICY documents_tenant_isolation ON documents
       USING (tenant_id = current_tenant()) WITH CHECK (true)"
echo "WITH CHECK weakened to true               $(run)"
restore

sql "DROP POLICY documents_tenant_isolation ON documents"
sql "CREATE POLICY documents_tenant_isolation ON documents USING (true)"
echo "policy weakened to USING (true)           $(run)"
restore

echo "restored                                  $(run)"
