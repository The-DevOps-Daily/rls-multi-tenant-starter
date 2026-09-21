"""Apply the schema and seed to a branch, as its owner. No psql needed."""
import os
import sys

import psycopg

if __name__ == "__main__":
    dsn = os.environ["NEON_OWNER_URL"]
    with psycopg.connect(dsn, autocommit=True) as c:
        for path in sys.argv[1:]:
            with open(path) as f:
                c.execute(f.read())
            print("applied %s" % path)
