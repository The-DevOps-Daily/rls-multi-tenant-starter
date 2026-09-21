"""
Run one statement against a Neon branch, for verify-suite.sh.

The Docker path issues its mutations through psql as the superuser, which owns
nothing and bypasses everything. Neon has no superuser, so the equivalent needs
two capabilities that are split across two roles: app_owner owns the tables and
can ALTER them, and neondb_owner holds BYPASSRLS and can therefore delete a
planted row that the policies would otherwise hide.

Granting app_owner to the current user with INHERIT gives one session both. It
is done here rather than in sql/01-schema.sql because it exists only to let the
mutation script work; the schema itself needs the SET part and nothing more.
"""
import os
import sys

import psycopg

if __name__ == "__main__":
    with psycopg.connect(os.environ["NEON_OWNER_URL"], autocommit=True) as c:
        c.execute("GRANT app_owner TO CURRENT_USER WITH SET TRUE, INHERIT TRUE")
        c.execute(sys.argv[1])
