# Multi-tenant Postgres with row-level security

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

A passing isolation suite means nothing on its own. One that queries an empty
table, or connects as a superuser, passes just as cheerfully against a table
with no policies at all.

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
syntax error, so using `SET` means interpolating the tenant id into the
statement as a string: an injection point in the one statement whose whole job
is enforcing the security boundary. `set_config()` is an ordinary function
call, so the value binds like any other parameter.

**2. The third argument to `set_config` is the whole pooling story.** `true`
means local to the transaction. With `false`, the value is session-scoped,
survives the commit, and belongs to whoever the pool hands that connection to
next. That is a cross-tenant read caused by one boolean.

**3. `ENABLE` does not bind the table's owner.** Migrations, admin scripts and
`psql` sessions run as the owner, which is exactly where an ad-hoc query is
most likely to touch every tenant at once. `FORCE` closes that.

**4. A superuser ignores all of it.** `FORCE` does not apply to a superuser: it
sees every tenant, with no setting and no policy evaluation. A connection
string that happens to be a superuser silently removes every guarantee here,
which is why this schema creates two ordinary roles and uses neither `postgres`
nor the owner for the application.

**5. Omitting `WITH CHECK` is safe; writing a weak one is not.** Postgres reuses
the `USING` expression for writes when `WITH CHECK` is absent. The hazard is the
opposite: `WITH CHECK (true)` reads like a formality and lets any tenant insert
rows into any other. That mutation is in `verify-suite.sh`, and exactly one test
catches it.

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
