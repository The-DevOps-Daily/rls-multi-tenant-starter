"""
The four ways this goes wrong in production.

These are not edge cases. Each one leaves a schema that looks correct, passes a
casual review, and leaks. They are tests rather than prose because a comment in
a migration is not enforcement.
"""
import psycopg
import pytest
from conftest import ACME, GLOBEX, as_tenant, titles


def test_set_local_does_not_outlive_its_transaction(conn):
    """
    The pooling bug.

    SET LOCAL is scoped to the transaction. On a pooled connection the next
    checkout starts clean, so it cannot inherit the previous request's tenant.
    """
    as_tenant(conn, ACME)
    assert len(titles(conn)) == 2
    conn.commit()

    # A fresh transaction on the same connection, as a pool would hand out.
    assert titles(conn) == []


def test_plain_set_leaks_across_transactions(conn):
    """
    The same thing done wrong, kept as a test so the difference is visible
    rather than asserted in a comment.

    Plain SET is session-scoped. On a pooled connection the tenant survives the
    commit and belongs to whoever is handed that connection next. That is a
    cross-tenant read caused by nothing but the word LOCAL being absent.
    """
    conn.execute("SELECT set_config('app.tenant_id', %s, false)", (ACME,))
    conn.commit()

    assert titles(conn) == ["Acme Q3 revenue", "Acme staff list"]
    conn.execute("RESET app.tenant_id")
    conn.commit()


def test_force_is_what_binds_the_table_owner(owner_conn):
    """
    ENABLE ROW LEVEL SECURITY does not apply to the table's owner. Migrations,
    admin scripts and psql sessions run as the owner, which is exactly where an
    ad-hoc query is most likely to touch every tenant at once.

    FORCE closes that, so the owner sees two rows here rather than four.
    """
    owner_conn.execute("SELECT set_config('app.tenant_id', %s, true)", (ACME,))
    assert len(titles(owner_conn)) == 2


def test_row_security_off_does_not_rescue_the_owner(owner_conn):
    """
    row_security = off is not an escape hatch for a role that cannot bypass
    policies. It is a request to error rather than silently filter.

    Postgres accepts the SET and then refuses the query: "query would be
    affected by row-level security policy". So the owner of a FORCEd table
    cannot quietly read every tenant by turning a setting off, and an operator
    who tries gets a refusal rather than a partial answer they might mistake
    for the whole table.
    """
    owner_conn.execute("SET LOCAL row_security = off")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        titles(owner_conn)


def test_a_superuser_ignores_all_of_this(superuser_conn):
    """
    The limit of the whole design, and the reason the schema creates two
    ordinary roles instead of using postgres.

    FORCE does not apply to a superuser. It sees every tenant with no setting,
    no policy evaluation and nothing to opt out of. Any connection string in
    the application that happens to be a superuser silently removes every
    guarantee the rest of this suite proves.
    """
    assert len(titles(superuser_conn)) == 4


def test_the_app_role_gains_nothing_by_opting_out(conn):
    """
    The same refusal for the application role.

    Note where it happens: the SET succeeds and the SELECT fails. Code that
    checks whether a statement raised, rather than whether the query returned,
    would read this as having turned the policies off. It did not.
    """
    as_tenant(conn, ACME)
    conn.execute("SET LOCAL row_security = off")
    with pytest.raises(psycopg.errors.InsufficientPrivilege):
        titles(conn)


def test_aggregates_respect_the_policy(conn):
    """
    Policies filter rows, so counts, sums and EXISTS see the filtered set too.
    Worth stating because dashboards are where a leak is least likely to be
    noticed: a number is not obviously somebody else's.
    """
    as_tenant(conn, ACME)
    assert conn.execute("SELECT count(*) FROM documents").fetchone()[0] == 2
    conn.rollback()
    as_tenant(conn, GLOBEX)
    assert conn.execute("SELECT count(*) FROM documents").fetchone()[0] == 2
