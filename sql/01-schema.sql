-- Multi-tenant schema with row-level security.
--
-- The whole design rests on one idea: the application never filters by tenant.
-- It sets who it is, and the database decides what that identity can see. A
-- forgotten WHERE clause then cannot leak another tenant's rows, because the
-- WHERE clause was never what was protecting them.

CREATE TABLE tenants (
    id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL
);

CREATE TABLE documents (
    id        uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    title     text NOT NULL,
    body      text NOT NULL DEFAULT '',

    -- Tenant-scoped, not a globally unique id.
    --
    -- Constraints are checked outside the policy, so a globally unique id is a
    -- cross-tenant existence oracle: insert a guessed id and a unique violation
    -- tells you another tenant holds it, without you ever being able to read
    -- the row. Scoping the key to the tenant removes that channel. It also
    -- puts tenant_id first in the index, which is the column every query
    -- filters on anyway.
    PRIMARY KEY (tenant_id, id)
);

-- Two roles, neither of them a superuser.
--
-- app_owner owns the tables and runs migrations. app_user is what the
-- application connects as. Keeping them apart is what makes FORCE meaningful:
-- a table owner is exempt from its own policies unless forced, and if the
-- owner were also the superuser no amount of forcing would matter.
CREATE ROLE app_owner LOGIN PASSWORD 'owner_password';
CREATE ROLE app_user  LOGIN PASSWORD 'app_password';

ALTER TABLE tenants   OWNER TO app_owner;
ALTER TABLE documents OWNER TO app_owner;

GRANT SELECT, INSERT, UPDATE, DELETE ON tenants, documents TO app_user;

-- Who am I? The app sets this per transaction; the policies read it.
--
-- current_setting with the second argument true returns NULL rather than
-- raising when the setting is absent. That is deliberate: an unset tenant
-- must produce "no rows", not an error that some middleware swallows into a
-- 500 and a retry.
CREATE FUNCTION current_tenant() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('app.tenant_id', true), '')::uuid
$$;

ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants   ENABLE ROW LEVEL SECURITY;

-- ENABLE is not enough for the table's owner. Postgres exempts the owner from
-- its own policies unless you also FORCE, and migrations usually run as the
-- owner. Without this line the policies look present and do nothing for the
-- one role most likely to run an ad-hoc query.
ALTER TABLE documents FORCE ROW LEVEL SECURITY;
ALTER TABLE tenants   FORCE ROW LEVEL SECURITY;

-- Worth being explicit about what FORCE does not do: it has no effect on a
-- superuser. A superuser bypasses row-level security entirely, whatever the
-- table says. That is why the application and its migrations must not connect
-- as one, and why this file creates two ordinary roles instead.

-- USING controls which rows are visible to SELECT, UPDATE and DELETE.
-- WITH CHECK controls which rows may be written by INSERT and UPDATE.
--
-- Omitting WITH CHECK is safe: Postgres reuses the USING expression for writes
-- when it is absent. The danger is the opposite, writing an explicit WITH CHECK
-- that is weaker than USING. `WITH CHECK (true)` reads like a formality and
-- lets any tenant insert rows belonging to any other. Stating it explicitly
-- and identically is the version that survives someone editing one line later.
CREATE POLICY documents_tenant_isolation ON documents
    USING      (tenant_id = current_tenant())
    WITH CHECK (tenant_id = current_tenant());

CREATE POLICY tenants_self ON tenants
    USING      (id = current_tenant())
    WITH CHECK (id = current_tenant());
