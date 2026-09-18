"""
Fixtures for the isolation tests.

The isolation tests connect as `app_user`, an unprivileged role. That is not a
detail: a table's owner is exempt from its own policies unless they are FORCEd,
and a superuser is exempt regardless.

Owner and superuser fixtures exist further down, but only so that the gotcha
tests can show what each of them changes. No isolation claim rests on them.
"""
import os
import psycopg
import pytest

ACME = "11111111-1111-1111-1111-111111111111"
GLOBEX = "22222222-2222-2222-2222-222222222222"

DSN = os.environ.get(
    "RLS_DEMO_DSN",
    "postgresql://app_user:app_password@127.0.0.1:55432/rlsdemo",
)
OWNER_DSN = os.environ.get(
    "RLS_DEMO_OWNER_DSN",
    "postgresql://app_owner:owner_password@127.0.0.1:55432/rlsdemo",
)
# A superuser, used only to show what it ignores.
SUPERUSER_DSN = os.environ.get(
    "RLS_DEMO_SUPERUSER_DSN",
    "postgresql://postgres:demo@127.0.0.1:55432/rlsdemo",
)


@pytest.fixture
def conn():
    """A connection as the unprivileged application role."""
    with psycopg.connect(DSN, autocommit=False) as c:
        yield c
        c.rollback()


@pytest.fixture
def owner_conn():
    """The table owner, a normal role. Used to show what FORCE changes."""
    with psycopg.connect(OWNER_DSN, autocommit=False) as c:
        yield c
        c.rollback()


@pytest.fixture
def superuser_conn():
    """A superuser. Used to show that it ignores all of this."""
    with psycopg.connect(SUPERUSER_DSN, autocommit=False) as c:
        yield c
        c.rollback()


def as_tenant(conn, tenant_id):
    """
    Adopt a tenant for the current transaction.

    set_config, not SET. Two reasons, and the second is the important one.

    The third argument, true, means local to the transaction, so the value
    cannot outlive it on a pooled connection and be inherited by whoever is
    handed that connection next. test_gotchas.py shows what plain SET does.

    And SET does not accept bind parameters. `SET LOCAL app.tenant_id = $1` is
    a syntax error, so using SET means interpolating the tenant id into the
    statement as a string: an injection point in the one statement whose whole
    job is enforcing the security boundary. set_config is an ordinary function
    call, so the value is bound like any other parameter.
    """
    conn.execute("SELECT set_config('app.tenant_id', %s, true)", (str(tenant_id),))


def titles(conn):
    return sorted(r[0] for r in conn.execute("SELECT title FROM documents").fetchall())
