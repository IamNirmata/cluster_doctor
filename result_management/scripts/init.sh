#!/usr/bin/env bash
set -euo pipefail

POD="${POD:-gcr-admin-pvc-access}"
NAMESPACE="${NAMESPACE:-gcr-admin}"
DB_PATH="${DB_PATH:-/data/continuous_validation/metadata/validation.db}"

echo "Initializing DB remotely on pod ${POD} (ns: ${NAMESPACE})..."

kubectl -n "$NAMESPACE" exec -i "$POD" -- python3 -c "
import sqlite3, os, sys
db_path = '${DB_PATH}'
try:
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute('PRAGMA journal_mode=WAL;')
    conn.execute('PRAGMA synchronous=NORMAL;')
    conn.execute(\"CREATE TABLE IF NOT EXISTS runs (node TEXT NOT NULL, test TEXT NOT NULL, timestamp INTEGER NOT NULL, result TEXT NOT NULL CHECK (result IN ('pass','fail','incomplete')));\")
    conn.execute('CREATE INDEX IF NOT EXISTS idx_runs_node_test_ts ON runs(node, test, timestamp);')
    conn.execute(\"CREATE VIEW IF NOT EXISTS latest_status AS SELECT r.node, r.test, r.timestamp AS latest_timestamp, r.result FROM runs r JOIN (SELECT node, test, MAX(timestamp) AS max_ts FROM runs GROUP BY node, test) x ON r.node=x.node AND r.test=x.test AND r.timestamp=x.max_ts;\")
    conn.commit()
    print(f'Initialized DB at {db_path}')
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
"
