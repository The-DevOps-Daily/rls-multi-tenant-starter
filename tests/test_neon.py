"""
What changes when this schema runs on Neon.

These tests are skipped unless the Neon connection strings are set, so the
Docker suite is unaffected. `./run-on-neon.sh` sets them.

Nothing here is a criticism of Neon. Each one is a consequence of a managed
Postgres having no superuser and putting a connection pooler in front of the
compute, and each one changes how you have to write the schema above.
"""
import os
import uuid

import psycopg
import pytest

from conftest import ACME, as_tenant, titles

POOLED_DSN = os.environ.get("RLS_DEMO_POOLED_DSN")
BYPASSRLS_DSN = os.environ.get("RLS_DEMO_BYPASSRLS_DSN")

needs_pooler = pytest.mark.skipif(not POOLED_DSN, reason="RLS_DEMO_POOLED_DSN not set")
needs_neon_owner = pytest.mark.skipif(not BYPASSRLS_DSN, reason="RLS_DEMO_BYPASSRLS_DSN not set")


@needs_neon_owner
def test_the_role_neon_gives_you_skips_every_policy():
    """
    The headline, and the reason this repo creates its own roles.

    neondb_owner is the role in the connection string the Neon console shows
    you, and the one most applications end up using. It holds BYPASSRLS. With
    a tenant set and FORCE ROW LEVEL SECURITY on the table, it still reads
    every tenant's rows.

    FORCE does not help. FORCE binds the table's owner. It has nothing to say
    about a role that skips policy evaluation altogether.
    """
    with psycopg.connect(BYPASSRLS_DSN, autocommit=False) as c:
        bypasses = c.execute(
            "SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user"
        ).fetchone()[0]
        assert bypasses is True, "expected the Neon owner role to hold BYPASSRLS"

        as_tenant(c, ACME)
        # Four titles across two tenants. Acme alone would be two.
        assert len(titles(c)) == 4
        c.rollback()


@needs_pooler
def test_the_application_role_still_cannot_see_other_tenants_through_the_pooler():
    """
    The pooler is not a hole on its own. The same policy applies behind it.
    """
    with psycopg.connect(POOLED_DSN, autocommit=False) as c:
        as_tenant(c, ACME)
        assert len(titles(c)) == 2
        c.rollback()


@needs_pooler
def test_a_transaction_setting_does_not_outlive_the_transaction_on_the_pooler():
    """
    The safe pattern, checked where it matters.

    set_config(..., true) is scoped to the transaction, so the value is gone at
    COMMIT and the connection goes back to the pool carrying nothing. With no
    tenant the policy denies everything, which is the correct way to fail.
    """
    with psycopg.connect(POOLED_DSN, autocommit=False) as c:
        as_tenant(c, ACME)
        assert len(titles(c)) == 2
        c.commit()

        assert c.execute("SELECT current_setting('app.tenant_id', true)").fetchone()[0] in (None, "")
        assert titles(c) == []
        c.rollback()


@needs_pooler
def test_a_session_setting_reaches_a_client_that_never_set_it():
    """
    Why the third argument to set_config is not a style preference.

    A pooled endpoint hands one server connection to many clients. A session
    scoped setting, set_config(..., false) or a plain SET, stays on the server
    connection after the client that set it has finished with it, and the next
    client inherits it.

    The probe uses a setting of its own rather than app.tenant_id, so a leak
    cannot contaminate the tests above. The consequence is the same: the value
    the policies read is a value another request left behind.

    Several clients are opened because a leak is only observed by whoever is
    handed that particular server connection.
    """
    probe = str(uuid.uuid4())

    with psycopg.connect(POOLED_DSN, autocommit=True) as setter:
        setter.execute("SELECT set_config('app.leak_probe', %s, false)", (probe,))

        inherited = 0
        readers = [psycopg.connect(POOLED_DSN, autocommit=True) for _ in range(8)]
        try:
            for r in readers:
                seen = r.execute("SELECT current_setting('app.leak_probe', true)").fetchone()[0]
                if seen == probe:
                    inherited += 1
        finally:
            # Scrub what this test left on every server connection it touched.
            for r in readers:
                r.execute("SELECT set_config('app.leak_probe', '', false)")
                r.close()
        setter.execute("SELECT set_config('app.leak_probe', '', false)")

    assert inherited > 0, (
        "no client inherited the session setting; the endpoint may not be the pooled one"
    )
