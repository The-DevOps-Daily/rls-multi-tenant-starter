# Multi-tenant Postgres with row-level security, on Neon

> Written up at [Your Tenant Isolation Is One Forgotten WHERE Clause Away](https://devops-daily.com/posts/postgres-row-level-security-multi-tenant)

A small, complete multi-tenant schema where **the application never filters by
tenant**. It says who it is; the database decides what that identity can see.

A forgotten `WHERE tenant_id = ...` then cannot leak another tenant's rows,
because the `WHERE` clause was never what was protecting them.

Twenty-two tests prove the isolation holds, and a second script proves the
tests are worth having by breaking the schema five ways and checking they
notice.

Four of those tests exist because **row-level security on Neon is not the same
exercise as row-level security on a Postgres you installed yourself**, and the
difference is not in your favour by default. [What changes on
Neon](#what-changes-on-neon) is the part to read if you skim.

## Run it on Neon

Each run makes a branch, applies the schema to it, runs the suite and deletes
the branch. A branch is a copy-on-write copy of its parent, so it costs nothing
to make and nothing the tests do can reach anything else. That is the whole
reason to test this on Neon rather than against a shared database: the roles,
the policies and the deliberately broken schema all disappear with the branch.

```bash
export NEON_API_KEY=...        # console.neon.tech, Account settings, API keys
export NEON_PROJECT_ID=...     # the project to branch from
./run-on-neon.sh
```

```
==> creating branch rls-test-1789987162
==> applying schema and seed
==> running the suite
22 passed in 13.89s
==> deleting branch br-billowing-voice-b2pp3j4i
```

Nothing is installed outside a local virtualenv, and no `psql` is needed.

## Run it offline

Postgres 18 in Docker, schema and seed applied by the entrypoint, suite run,
container removed. The four Neon tests skip themselves when the Neon
connection strings are absent, so eighteen run.

```bash
./run-tests.sh
```

## What changes on Neon

Neon has no superuser and puts a connection pooler in front of the compute.
Both are reasonable choices for a managed database, and between them they
change four things about this schema. Each one is a test in
`tests/test_neon.py` or a comment in the SQL explaining a line that would
otherwise look superstitious.

### The role in your connection string skips every policy

This is the one that matters. `neondb_owner` is the role in the connection
string the console hands you, and the one most applications end up using. It
holds `BYPASSRLS`:

```sql
SELECT rolname, rolbypassrls FROM pg_roles WHERE rolname = current_user;
--  neondb_owner | t
```

With a tenant set and `FORCE ROW LEVEL SECURITY` on the table, it still reads
every tenant:

```
role=neondb_owner  bypassrls=true   rows=4  -> Acme Q3 revenue, Acme staff list, Globex Q3 revenue, Globex staff list
role=app_user      bypassrls=false  rows=2  -> Acme Q3 revenue, Acme staff list
```

`FORCE` does not help. `FORCE` binds the table's *owner*; it has nothing to say
about a role that skips policy evaluation altogether. Write every policy you
like: against that role they are decoration.

So make your own role. That is what `sql/01-schema.sql` does, and why it uses
neither the role Neon gave you nor the table owner for the application.

### A session setting on the pooled endpoint reaches the next client

The pooled endpoint, the host with `-pooler` in it, hands one server connection
to many clients. A session-scoped `set_config(..., false)`, or a plain `SET`,
stays on that server connection after the client that set it has gone, and the
next client inherits it.

Measured on the pooled endpoint: client A sets a value, client B never sets
anything, and client B reads client A's value back. With `app.tenant_id` that
is one tenant's identity being adopted by another tenant's request.

`set_config(..., true)` is scoped to the transaction, so the connection goes
back to the pool carrying nothing. It is the third argument, and it is the
whole difference.

### Creating a role gives you the admin option but not `SET ROLE`

`ALTER TABLE ... OWNER TO app_owner` requires that you be able to `SET ROLE` to
the new owner. Creating the role usually grants that. On Neon the membership
comes back with `set_option = false`:

```
role        granted_to      admin_option  inherit_option  set_option
app_owner   neondb_owner    true          false           false
```

so the statement fails with `must be able to SET ROLE "app_owner"`. The admin
option is there, so the role can hand itself the missing part:

```sql
GRANT app_owner TO CURRENT_USER WITH SET TRUE;
```

The same check is why `DROP OWNED BY` fails with `permission denied to drop
objects` when tearing the demo down.

### The new owner needs `CREATE` on the schema, and the passwords need to be real

Two smaller ones. `ALTER TABLE ... OWNER TO` also requires the new owner to
hold `CREATE` on the schema, a check a local superuser skips and Neon does not,
so it fails with `permission denied for schema public`.

And Neon validates passwords in its control plane, so `CREATE ROLE app_user
LOGIN PASSWORD 'app_password'` fails the statement with an HTTP 400 and
`insecure password, try including more special characters`. A demo with cute
passwords does not run here.

## Prove the tests are not lying

A passing isolation suite is weak evidence on its own. The usual ways one lies
are querying an empty table, connecting as a role that bypasses policies, or
asserting "cannot see the other tenant" without ever checking the other tenant
exists. The suite here guards against all three, and this script is how that
claim is checked rather than asserted.

```bash
./run-on-neon.sh verify     # on a throwaway branch
./verify-suite.sh           # against the Docker database
```

It breaks the schema on purpose and re-runs the suite each time. Measured on a
Neon branch:

```
  ok    baseline                                   22 passed
  ok    RLS disabled on documents                  16 failed, 6 passed
  ok    RLS disabled on tenants                    2 failed, 20 passed
  ok    FORCE removed, owner exempt again          2 failed, 20 passed
  ok    WITH CHECK weakened to true                1 failed, 21 passed
  ok    policy weakened to USING (true)            14 failed, 8 passed
  ok    restored                                   22 passed

every mutation was caught.
```

Every weakening is caught by at least one test, and the counts say which ones.
Removing `FORCE` trips exactly the two tests about the table owner, which is
what you want: a precise failure tells you what broke. The script exits
non-zero if any mutation goes unnoticed.

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
sql/01-schema.sql        tables, roles, policies, and the Neon-only grants
sql/02-seed.sql          two tenants with equal-sized data
neon/branch.py           make and delete the branch a run happens on
neon/apply.py            apply the SQL files, so no psql is needed
neon/exec.py             one statement as an owner, for the mutation script
neon/reset.sql           drop the demo objects, for a branch whose parent has them
tests/conftest.py        connects as the unprivileged role, never the owner
tests/test_isolation.py  the claims: read, insert, update, delete, no tenant
tests/test_gotchas.py    the portable traps, as tests rather than comments
tests/test_neon.py       the four above, skipped when not running on Neon
run-on-neon.sh           branch, apply, run, delete
run-tests.sh             the same suite against Docker
verify-suite.sh          breaks the schema to prove the tests catch it
```


## What this is not

Not a framework, and not a complete application. There is no ORM integration,
no connection-pool middleware and no auth. It is the database half of a
multi-tenant system, small enough to read in one sitting and to lift the
policies out of.

MIT.
