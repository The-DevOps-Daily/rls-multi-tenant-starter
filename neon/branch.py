"""
Create and delete a Neon branch for one test run, and print the connection
strings the suite needs.

A branch is the point of running this on Neon rather than against a shared
database: it is a copy-on-write copy of the parent, it costs nothing to make,
and the roles and tables this suite creates disappear with it. Nothing the
tests do can reach the parent branch.

Usage:
    python neon/branch.py create <project_id> <branch_name>   -> prints env lines
    python neon/branch.py delete <project_id> <branch_id>
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

API = "https://console.neon.tech/api/v2"
OWNER_PASSWORD = "Ow2ner-Rls-Demo-2026!"
APP_PASSWORD = "Ap3pUser-Rls-Demo-2026!"


def call(method, path, body=None):
    key = os.environ.get("NEON_API_KEY")
    if not key:
        sys.exit("NEON_API_KEY is not set")
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        sys.exit("Neon API %s %s: %s" % (method, path, e.read().decode()[:400]))


def with_role(uri, role, password):
    """Swap the role and password in a connection URI, leaving the host alone."""
    scheme, rest = uri.split("://", 1)
    _, hostpart = rest.split("@", 1)
    return "%s://%s:%s@%s" % (scheme, role, password.replace("!", "%21"), hostpart)


def create(project_id, branch_name):
    out = call(
        "POST",
        "/projects/%s/branches" % project_id,
        {"branch": {"name": branch_name}, "endpoints": [{"type": "read_write"}]},
    )
    branch_id = out["branch"]["id"]

    # A new compute answers the API before it is ready to take work.
    for _ in range(15):
        state = call("GET", "/projects/%s/branches/%s" % (project_id, branch_id))
        if state["branch"].get("current_state") == "ready":
            break
        time.sleep(2)

    # A branch creation response carries no connection_uris, because the roles
    # come from the parent rather than being made here. Ask for the URI.
    dbs = call("GET", "/projects/%s/branches/%s/databases" % (project_id, branch_id))["databases"]
    db = dbs[0]
    uri = call(
        "GET",
        "/projects/%s/connection_uri?branch_id=%s&database_name=%s&role_name=%s"
        % (project_id, branch_id, db["name"], db["owner_name"]),
    )["uri"]

    # The API hands back the pooled host. Both are the same name with and
    # without -pooler, and the tests need each of them.
    pooled = uri
    direct = uri.replace("-pooler.", ".", 1)

    def emit(name, value):
        # Single quoted: a connection URI carries & and ?, and an unquoted
        # assignment in `. env` would background the line at the first &.
        print("%s='%s'" % (name, value))

    emit("NEON_BRANCH_ID", branch_id)
    emit("NEON_OWNER_URL", direct)
    emit("RLS_DEMO_DSN", with_role(direct, "app_user", APP_PASSWORD))
    emit("RLS_DEMO_OWNER_DSN", with_role(direct, "app_owner", OWNER_PASSWORD))
    # The role Neon puts in the console connection string. Not a superuser,
    # but it holds BYPASSRLS, which for row-level security amounts to the same.
    emit("RLS_DEMO_SUPERUSER_DSN", direct)
    emit("RLS_DEMO_BYPASSRLS_DSN", direct)
    emit("RLS_DEMO_POOLED_DSN", with_role(pooled, "app_user", APP_PASSWORD))


def delete(project_id, branch_id):
    call("DELETE", "/projects/%s/branches/%s" % (project_id, branch_id))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    action, project_id, arg = sys.argv[1], sys.argv[2], sys.argv[3]
    if action == "create":
        create(project_id, arg)
    elif action == "delete":
        delete(project_id, arg)
    else:
        sys.exit(__doc__)
