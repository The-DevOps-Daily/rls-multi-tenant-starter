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
-- The passwords are long and mixed on purpose. Neon validates them in its
-- control plane, and CREATE ROLE with a short one fails the statement with an
-- HTTP 400, not a Postgres error: "insecure password, try including more
-- special characters". A demo that uses 'app_password' does not run on Neon.
CREATE ROLE app_owner LOGIN PASSWORD 'Ow2ner-Rls-Demo-2026!';
CREATE ROLE app_user  LOGIN PASSWORD 'Ap3pUser-Rls-Demo-2026!';

-- Two grants that only Neon needs, and that only Neon explains.
--
-- On a local Postgres the entrypoint runs as a superuser, which is exempt from
-- both checks below, so the ALTER TABLE statements that follow just work. On
-- Neon nothing is a superuser, and each check fires in turn.
--
-- 1. ALTER TABLE ... OWNER TO requires the current user to be able to SET ROLE
--    to the new owner. Creating a role usually grants that implicitly, but on
--    Neon the membership comes back with set_option = false, so the statement
--    fails with: must be able to SET ROLE "app_owner". The admin option is
--    granted, so the role can hand itself the missing part.
--
-- 2. The new owner must hold CREATE on the schema that holds the table.
DO $neon$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'neon_superuser') THEN
        EXECUTE 'GRANT app_owner TO CURRENT_USER WITH SET TRUE';
        EXECUTE 'GRANT CREATE ON SCHEMA public TO app_owner';
    END IF;
END
$neon$;

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
-- role holding BYPASSRLS. Such a role skips row-level security entirely,
-- whatever the table says. Every superuser has it implicitly.
--
-- On Neon this is the trap, because you do not have to reach for a superuser
-- to hit it. The role in the connection string the console shows you,
-- neondb_owner, has rolbypassrls = true. Paste that into an application and
-- every policy below is decoration. Check before you trust it:
--
--     SELECT rolname, rolbypassrls FROM pg_roles WHERE rolname = current_user;
--
-- That is why this file creates two ordinary roles instead of using the one
-- Neon hands you.

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
