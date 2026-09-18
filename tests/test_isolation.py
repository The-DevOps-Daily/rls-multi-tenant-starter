"""
The claims a multi-tenant system has to be able to make.

Each test states one of them and then tries to break it. Reading a row you
should not see is the obvious failure; writing one into someone else's tenant
is the one people forget to check for.
"""
import psycopg
import pytest
from conftest import ACME, GLOBEX, as_tenant, titles


def test_a_tenant_sees_only_its_own_rows(conn):
    as_tenant(conn, ACME)
    assert titles(conn) == ["Acme Q3 revenue", "Acme staff list"]

    conn.rollback()
    as_tenant(conn, GLOBEX)
    assert titles(conn) == ["Globex Q3 revenue", "Globex staff list"]


def test_the_table_really_does_hold_both_tenants(superuser_conn):
    """
    Guards every test above it. If the seed had failed, the isolation tests
    would all pass while proving nothing, because an empty table leaks nothing.

    A superuser is the honest way to count: it bypasses row-level security
    entirely, so it sees the table as it really is.
    """
    total = superuser_conn.execute("SELECT count(*) FROM documents").fetchone()[0]
    assert total == 4


def test_selecting_another_tenant_by_id_returns_nothing(conn):
    """No error, no rows. The row is not hidden behind a permission failure."""
    as_tenant(conn, ACME)
    rows = conn.execute(
        "SELECT title FROM documents WHERE tenant_id = %s", (GLOBEX,)
    ).fetchall()
    assert rows == []


def test_insert_into_another_tenant_is_refused(conn):
    """
    Enforced by WITH CHECK. Note that omitting WITH CHECK entirely would also
    be safe, because Postgres reuses USING for writes; the hazard is writing an
    explicit one that is weaker, which verify-suite.sh demonstrates.
    """
    as_tenant(conn, ACME)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        conn.execute(
            "INSERT INTO documents (tenant_id, title) VALUES (%s, %s)",
            (GLOBEX, "planted by Acme"),
        )


def test_moving_your_own_row_to_another_tenant_is_refused(conn):
    """
    The subtle one. The row is visible, so USING passes and the UPDATE is
    allowed to proceed; WITH CHECK is what rejects the new tenant_id.
    """
    as_tenant(conn, ACME)
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        conn.execute(
            "UPDATE documents SET tenant_id = %s WHERE title = %s",
            (GLOBEX, "Acme Q3 revenue"),
        )


def test_updating_another_tenants_row_affects_nothing(conn):
    as_tenant(conn, ACME)
    cur = conn.execute(
        "UPDATE documents SET body = %s WHERE title = %s",
        ("tampered", "Globex Q3 revenue"),
    )
    assert cur.rowcount == 0


def test_deleting_another_tenants_row_affects_nothing(conn):
    as_tenant(conn, ACME)
    cur = conn.execute("DELETE FROM documents WHERE tenant_id = %s", (GLOBEX,))
    assert cur.rowcount == 0


def test_no_tenant_set_means_no_rows(conn):
    """
    Fail closed. current_tenant() is NULL, `tenant_id = NULL` is NULL, and a
    policy that does not evaluate true hides the row. A bug that forgets to set
    the tenant returns an empty page, not somebody else's data.
    """
    assert titles(conn) == []


def test_a_forged_tenant_id_sees_nothing(conn):
    as_tenant(conn, "33333333-3333-3333-3333-333333333333")
    assert titles(conn) == []


def test_the_tenants_table_is_isolated_too(conn):
    """
    Easy to forget. Without this, RLS could be disabled on `tenants` and every
    other test here would still pass, while the tenant list, and therefore the
    customer list, was readable by anyone.
    """
    as_tenant(conn, ACME)
    names = [r[0] for r in conn.execute("SELECT name FROM tenants").fetchall()]
    assert names == ["Acme"]


def test_a_tenant_cannot_rename_another(conn):
    as_tenant(conn, ACME)
    cur = conn.execute(
        "UPDATE tenants SET name = %s WHERE id = %s", ("owned", GLOBEX)
    )
    assert cur.rowcount == 0
