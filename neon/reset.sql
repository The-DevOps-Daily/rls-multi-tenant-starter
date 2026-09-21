-- Drop what this demo creates, so a run can start from any branch state.
--
-- A Neon branch is a copy of its parent, so if the parent already holds the
-- demo schema the branch inherits it and CREATE TABLE fails. This file only
-- ever names objects the demo itself creates, and it lives outside sql/ so
-- the Docker entrypoint never runs it. run-on-neon.sh applies it to the
-- throwaway branch, never to the parent.
DROP TABLE IF EXISTS documents CASCADE;
DROP TABLE IF EXISTS tenants CASCADE;
DROP FUNCTION IF EXISTS current_tenant() CASCADE;

DO $reset$
BEGIN
    -- DROP OWNED BY needs the ability to SET ROLE to the role being dropped.
    -- On Neon the membership that comes with CREATE ROLE has set_option =
    -- false, so this fails with "permission denied to drop objects" unless the
    -- role hands itself the missing part first. The admin option is there, so
    -- it can. On a local superuser the grant is a no-op.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        EXECUTE 'GRANT app_user TO CURRENT_USER WITH SET TRUE';
        EXECUTE 'DROP OWNED BY app_user CASCADE';
        EXECUTE 'DROP ROLE app_user';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_owner') THEN
        EXECUTE 'GRANT app_owner TO CURRENT_USER WITH SET TRUE';
        EXECUTE 'DROP OWNED BY app_owner CASCADE';
        EXECUTE 'DROP ROLE app_owner';
    END IF;
END
$reset$;
