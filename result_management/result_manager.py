#!/usr/bin/env python3
"""
cv_sqlite.py - Continuous Validation metadata using SQLite

DB path (default):
  /data/continuous_validation/metadata/validation.db

Tables / Views:
  runs(node, test, timestamp, result)   -- append-only history
  latest_status                         -- derived status view (latest per node,test)

Commands:
  init
  add
  status
  history
  export-csv
  export-json

Timestamps:
  - Recommended input: ISO-8601 UTC like 2025-12-29T17:20:00Z
  - Also accepts integer epoch seconds
Stored format in DB:
  - INTEGER epoch seconds (timestamp)
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import os
import sqlite3
import sys
import subprocess
import tempfile
from typing import Iterable, List, Tuple


ALLOWED_RESULTS = {"pass", "fail", "incomplete"}


# -----------------------
# Timestamp helpers
# -----------------------

def parse_timestamp_to_epoch(ts: str) -> int:
    ts = ts.strip()
    if not ts:
        raise ValueError("timestamp is empty")

    # epoch seconds?
    if ts.isdigit():
        return int(ts)

    # ISO 8601 (accept trailing Z)
    t = ts
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    d = dt.datetime.fromisoformat(t)
    if d.tzinfo is None:
        # Treat naive timestamps as UTC to avoid ambiguity
        d = d.replace(tzinfo=dt.timezone.utc)
    return int(d.timestamp())


def epoch_to_iso_utc(epoch: int) -> str:
    return dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# -----------------------
# SQLite helpers
# -----------------------

def connect(db_path: str) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    cur = conn.cursor()

    # Better concurrency for reads while writing (typical controller + observers)
    cur.execute("PRAGMA journal_mode=WAL;")
    cur.execute("PRAGMA synchronous=NORMAL;")

    cur.execute("""
      CREATE TABLE IF NOT EXISTS runs (
        node      TEXT NOT NULL,
        test      TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        result    TEXT NOT NULL CHECK (result IN ('pass','fail','incomplete'))
      );
    """)

    # Helps latest-status queries scale to lots of rows
    cur.execute("""
      CREATE INDEX IF NOT EXISTS idx_runs_node_test_ts
      ON runs(node, test, timestamp);
    """)

    # Status view: latest per (node,test)
    # Note: if two rows share same timestamp for a key, view may return both;
    # avoid duplicates by ensuring timestamps are unique per node/test or add a run_id column later.
    cur.execute("""
      CREATE VIEW IF NOT EXISTS latest_status AS
      SELECT r.node, r.test, r.timestamp AS latest_timestamp, r.result
      FROM runs r
      JOIN (
        SELECT node, test, MAX(timestamp) AS max_ts
        FROM runs
        GROUP BY node, test
      ) x
      ON r.node=x.node AND r.test=x.test AND r.timestamp=x.max_ts;
    """)

    conn.commit()


def insert_run(conn: sqlite3.Connection, node: str, test: str, epoch_ts: int, result: str) -> None:
    result = result.strip().lower()
    if result not in ALLOWED_RESULTS:
        raise ValueError(f"result must be one of: {', '.join(sorted(ALLOWED_RESULTS))}")

    conn.execute(
        "INSERT INTO runs(node, test, timestamp, result) VALUES (?,?,?,?)",
        (node, test, epoch_ts, result),
    )
    conn.commit()


def query_latest_status(conn: sqlite3.Connection, node_filter: str = None) -> List[sqlite3.Row]:
    query = "SELECT node, test, latest_timestamp, result FROM latest_status"
    params = []
    if node_filter:
        query += " WHERE node = ?"
        params.append(node_filter)
    query += " ORDER BY node, test"
    return conn.execute(query, params).fetchall()


def query_history_tail(conn: sqlite3.Connection, limit: int) -> List[sqlite3.Row]:
    return conn.execute(
        "SELECT node, test, timestamp, result FROM runs ORDER BY timestamp DESC LIMIT ?",
        (limit,),
    ).fetchall()


# -----------------------
# Remote DB helpers
# -----------------------

def fetch_remote_db(args) -> str:
    print(f"Fetching remote DB from {args.pod} (ns: {args.namespace})...")
    fd, temp_path = tempfile.mkstemp(suffix='.db')
    os.close(fd)
    
    cmd = [
        "kubectl", "-n", args.namespace, "exec", args.pod, "--",
        "cat", args.db
    ]
    try:
        with open(temp_path, "wb") as f:
            subprocess.check_call(cmd, stdout=f)
        return temp_path
    except subprocess.CalledProcessError as e:
        os.remove(temp_path)
        raise RuntimeError(f"Failed to fetch remote DB: {e}")

def run_remote_init(args) -> None:
    print(f"Initializing remote DB at {args.pod}:{args.db} ...")
    script = """
import sqlite3
import os
import sys

db_path = '{}'
try:
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("PRAGMA journal_mode=WAL;")
    cur.execute("PRAGMA synchronous=NORMAL;")
    cur.execute("CREATE TABLE IF NOT EXISTS runs (node TEXT NOT NULL, test TEXT NOT NULL, timestamp INTEGER NOT NULL, result TEXT NOT NULL CHECK (result IN ('pass','fail','incomplete')));")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_runs_node_test_ts ON runs(node, test, timestamp);")
    cur.execute("CREATE VIEW IF NOT EXISTS latest_status AS SELECT r.node, r.test, r.timestamp AS latest_timestamp, r.result FROM runs r JOIN (SELECT node, test, MAX(timestamp) AS max_ts FROM runs GROUP BY node, test) x ON r.node=x.node AND r.test=x.test AND r.timestamp=x.max_ts;")
    conn.commit()
    conn.close()
    print("Initialized DB at " + db_path)
except Exception as e:
    print(f"Error initializing DB: {e}", file=sys.stderr)
    sys.exit(1)
""".format(args.db)
    
    cmd = [
        "kubectl", "-n", args.namespace, "exec", args.pod, "--",
        "python3", "-c", script
    ]
    subprocess.check_call(cmd)


# -----------------------
# CLI commands
# -----------------------

def cmd_init(args: argparse.Namespace) -> None:
    if args.remote:
        run_remote_init(args)
        return

    conn = connect(args.db)
    try:
        init_db(conn)
    finally:
        conn.close()

    print(f"Initialized DB: {args.db}")
    print("Objects: table=runs, view=latest_status")


def cmd_add(args: argparse.Namespace) -> None:
    # add is always local (in pod)
    epoch = parse_timestamp_to_epoch(args.timestamp)

    conn = connect(args.db)
    try:
        init_db(conn)  # safe to call repeatedly
        insert_run(conn, args.node, args.test, epoch, args.result)
    finally:
        conn.close()

    print("Inserted 1 run:")
    print(f"  node={args.node}")
    print(f"  test={args.test}")
    print(f"  timestamp={epoch_to_iso_utc(epoch)} ({epoch})")
    print(f"  result={args.result.lower()}")


def cmd_status(args: argparse.Namespace) -> None:
    db_path = args.db
    temp_path = None
    
    if args.remote:
        try:
            temp_path = fetch_remote_db(args)
            db_path = temp_path
        except RuntimeError as e:
            print(f"Error: {e}", file=sys.stderr)
            return

    conn = connect(db_path)
    try:
        init_db(conn)
        rows = query_latest_status(conn, args.node)
    finally:
        conn.close()
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)

    # Print as a simple table
    print("node\ttest\tlatest_timestamp\tresult")
    for r in rows:
        print(f"{r['node']}\t{r['test']}\t{epoch_to_iso_utc(r['latest_timestamp'])}\t{r['result']}")


def cmd_history(args: argparse.Namespace) -> None:
    db_path = args.db
    temp_path = None
    
    if args.remote:
        try:
            temp_path = fetch_remote_db(args)
            db_path = temp_path
        except RuntimeError as e:
            print(f"Error: {e}", file=sys.stderr)
            return

    conn = connect(db_path)
    try:
        init_db(conn)
        rows = query_history_tail(conn, args.tail)
    finally:
        conn.close()
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)

    print("node\ttest\ttimestamp\tresult")
    for r in rows:
        print(f"{r['node']}\t{r['test']}\t{epoch_to_iso_utc(r['timestamp'])}\t{r['result']}")


def cmd_export_csv(args: argparse.Namespace) -> None:
    db_path = args.db
    temp_path = None
    
    if args.remote:
        try:
            temp_path = fetch_remote_db(args)
            db_path = temp_path
        except RuntimeError as e:
            print(f"Error: {e}", file=sys.stderr)
            return

    conn = connect(db_path)
    try:
        init_db(conn)
        rows = query_latest_status(conn)
    finally:
        conn.close()
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["node", "test", "latest_timestamp", "result"])
        for r in rows:
            w.writerow([r["node"], r["test"], epoch_to_iso_utc(r["latest_timestamp"]), r["result"]])

    print(f"Wrote: {args.out} (rows={len(rows)})")


def cmd_export_json(args: argparse.Namespace) -> None:
    db_path = args.db
    temp_path = None
    
    if args.remote:
        try:
            temp_path = fetch_remote_db(args)
            db_path = temp_path
        except RuntimeError as e:
            print(f"Error: {e}", file=sys.stderr)
            return

    conn = connect(db_path)
    try:
        init_db(conn)
        rows = query_latest_status(conn)
    finally:
        conn.close()
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)

    payload = {
        "generated_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "latest": [
            {
                "node": r["node"],
                "test": r["test"],
                "latest_timestamp": epoch_to_iso_utc(r["latest_timestamp"]),
                "result": r["result"],
            }
            for r in rows
        ],
    }

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")

    print(f"Wrote: {args.out} (entries={len(rows)})")


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--db",
        default="/data/continuous_validation/metadata/validation.db",
        help="Path to SQLite DB on PVC",
    )
    ap.add_argument(
        "--remote",
        action="store_true",
        help="Access DB remotely via kubectl exec (for status/history/export/init)",
    )
    ap.add_argument(
        "--pod",
        default="gcr-admin-pvc-access",
        help="Pod name for remote access (default: gcr-admin-pvc-access)",
    )
    ap.add_argument(
        "--namespace",
        default="gcr-admin",
        help="Namespace for remote access (default: gcr-admin)",
    )
    
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("init", help="Create runs table + latest_status view")
    p.set_defaults(fn=cmd_init)

    p = sub.add_parser("add", help="Append one completed run (history row)")
    p.add_argument("--node", required=True)
    p.add_argument("--test", required=True)
    p.add_argument("--timestamp", required=True, help="ISO-8601 UTC (recommended) or epoch seconds")
    p.add_argument("--result", required=True, help="pass|fail|incomplete")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("status", help="Show latest status per (node,test) from view")
    p.add_argument("--node", help="Filter by node name")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("history", help="Show latest N history rows")
    p.add_argument("--tail", type=int, default=20)
    p.set_defaults(fn=cmd_history)

    p = sub.add_parser("export-csv", help="Export latest_status to CSV")
    p.add_argument("--out", default="/data/continuous_validation/metadata/status.csv")
    p.set_defaults(fn=cmd_export_csv)

    p = sub.add_parser("export-json", help="Export latest_status to JSON")
    p.add_argument("--out", default="/data/continuous_validation/metadata/status.json")
    p.set_defaults(fn=cmd_export_json)

    return ap


def main() -> None:
    ap = build_parser()
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
