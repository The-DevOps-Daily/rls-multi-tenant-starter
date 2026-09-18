# Multi-tenant Postgres with row-level security

> Written up at [Your Tenant Isolation Is One Forgotten WHERE Clause Away](https://devops-daily.com/posts/postgres-row-level-security-multi-tenant)


A small, complete multi-tenant schema where **the application never filters by
tenant**. It says who it is; the database decides what that identity can see.

A forgotten `WHERE tenant_id = ...` then cannot leak another tenant's rows,
because the `WHERE` clause was never what was protecting them.

Sixteen tests prove the isolation holds, and a second script proves the tests
are worth having by breaking the schema four ways and checking they notice.

## Run it

```bash
./run-tests.sh
```

Postgres 18 in Docker, schema and seed applied by the entrypoint, suite run,
container removed. Nothing is installed outside a local virtualenv.

```
16 passed in 0.55s
```

## Prove the tests are not lying

A passing isolation suite is weak evidence on its own. The usual ways one lies
are querying an empty table, connecting as a role that bypasses policies, or
asserting "cannot see the other tenant" without ever checking the other tenant
exists. The suite here guards against all three, and this script is how that
claim is checked rather than asserted.

```bash
./verify-suite.sh
```

It breaks the schema on purpose and re-runs the suite each time:

```
baseline                                  16 passed
RLS disabled entirely                     14 failed, 2 passed
FORCE removed (owner exempt again)        2 failed, 14 passed
WITH CHECK weakened to true               1 failed, 15 passed
policy weakened to USING (true)           12 failed, 4 passed
restored                                  16 passed
```

Every weakening is caught by at least one test, and the counts say which ones.
Removing `FORCE` trips exactly the two tests about the table owner, which is
what you want: a precise failure tells you what broke.

## What the schema does

```sql
CREATE FUNCTION current_tenant() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('app.tenant_id', true), '')::uuid
$$;

ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE  ROW LEVEL SECURITY;

CREATE POLICY documents_tenant_isolation ON documents
    USING      (tenant_id = current_tenant())
    WITH CHECK (tenant_id = current_tenant());
```

The application adopts a tenant for the transaction:

```python
conn.execute("SELECT set_config('app.tenant_id', %s, true)", (tenant_id,))
```

## Five things that are easy to get wrong

**1. `SET` cannot take a bind parameter.** `SET LOCAL app.tenant_id = $1` is a
syntax error, so `SET` forces you to build the statement as a string. That is
safe if you quote it properly, with psycopg's `sql.Literal` or equivalent, and
it is an injection point the moment somebody reaches for an f-string, in the
one statement whose whole job is the security boundary. `set_config()` takes an
ordinary bind parameter, so the question does not arise.

**2. The third argument to `set_config` decides whether a pooled connection
leaks.** `true` means local to the transaction, the same scope as `SET LOCAL`.
With `false` the value is session-scoped, survives the commit, and belongs to
whoever the pool hands that connection to next.

Two conditions come with it, and both have bitten people. The setting and the
queries it protects must be in the **same transaction**, so in autocommit a
lone `set_config(..., true)` has expired by the next statement. And a
transaction-local value restores the *session* value underneath it, not an
empty one, so a stale session-level tenant can reappear after the commit. Never
setting a session-level tenant at all is what makes the local one safe.

**3. `ENABLE` does not bind the table's owner.** Migrations, admin scripts and
`psql` sessions run as the owner, which is exactly where an ad-hoc query is
most likely to touch every tenant at once. `FORCE` closes that.

**4. A superuser ignores all of it, and so does `BYPASSRLS`.** `FORCE` does not
apply to a superuser: it sees every tenant, with no setting and no policy
evaluation. The same is true of any role granted `BYPASSRLS`, which needs no
superuser status at all and is easy to grant to "the analytics user" without
thinking. A connection string that happens to be either silently removes every
guarantee here, which is why this schema creates two ordinary roles and uses
neither `postgres` nor the owner for the application.

`FORCE` also constrains an owner who is behaving, not one who is not: the owner
can drop the policies. It is a guard against the accidental `psql` session, not
against a hostile migration.

**5. Omitting `WITH CHECK` is safe; writing a weak one is not.** Postgres reuses
the `USING` expression for writes when `WITH CHECK` is absent. The hazard is the
opposite: `WITH CHECK (true)` reads like a formality and lets any tenant insert
rows into any other. That mutation is in `verify-suite.sh`, and exactly one test
catches it.

## What row-level security does not do

It filters rows. It does not make a tenant's data unknowable.

`EXPLAIN ANALYZE` on a sequential scan reports how many rows the tenant filter
removed, which is a count of somebody else's data. Planner estimates and
timings carry information too. None of that reaches a normal API response, but
it is worth knowing before "the database enforces isolation" becomes "nothing
can be inferred", because those are different claims and only the first one is
true here.

The same applies to constraints, which are checked outside the policy. That is
why `documents` uses a tenant-scoped primary key rather than a global one.

## Layout

```
sql/01-schema.sql     tables, roles, policies
sql/02-seed.sql       two tenants with equal-sized data
tests/conftest.py     connects as the unprivileged role, never the owner
tests/test_isolation.py  the claims: read, insert, update, delete, no tenant
tests/test_gotchas.py    the five above, as tests rather than comments
verify-suite.sh       breaks the schema to prove the tests catch it
```

## What this is not

Not a framework, and not a complete application. There is no ORM integration,
no connection-pool middleware and no auth. It is the database half of a
multi-tenant system, small enough to read in one sitting and to lift the
policies out of.

MIT.
