#!/usr/bin/env python3
"""Zero OpenCode token/context counters without deleting chat history.

OpenCode stores cumulative usage in session_v2, but the "used context" ring in
the UI is calculated from the token usage attached to the last assistant
message. To make the reset real, this helper zeroes both:

  * session_v2.cost and the five tokens_* columns
  * session_message.data["tokens"] and .data["cost"] for rows that have usage

Message content, parts, titles, timestamps and session history are not touched.

The database is backed up with SQLite's online backup API before any write.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import time
from pathlib import Path
from typing import Any

TOKEN_COLUMNS = (
    "tokens_input",
    "tokens_output",
    "tokens_reasoning",
    "tokens_cache_read",
    "tokens_cache_write",
)


def emit(payload: dict[str, Any]) -> None:
    # ASCII-only keeps this safe on every Windows console/code page.
    print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))


def fail(message: str, **extra: Any) -> None:
    payload = {"ok": False, "error": message}
    payload.update(extra)
    emit(payload)
    raise SystemExit(1)


def norm_path(value: str) -> str:
    if not value:
        return ""
    value = os.path.abspath(os.path.expanduser(value))
    return os.path.normcase(os.path.normpath(value)).replace("\\", "/").rstrip("/")


def default_db() -> Path:
    return Path(os.path.expandvars(r"%USERPROFILE%\.local\share\opencode\opencode.db"))


def connect(db: Path, *, read_only: bool = False, timeout: int = 30) -> sqlite3.Connection:
    if read_only:
        uri = "file:" + str(db).replace("\\", "/") + "?mode=ro"
        con = sqlite3.connect(uri, uri=True, timeout=timeout)
    else:
        con = sqlite3.connect(str(db), timeout=timeout)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout = %d" % (timeout * 1000))
    return con


def table_exists(con: sqlite3.Connection, name: str) -> bool:
    row = con.execute(
        "select 1 from sqlite_master where type='table' and name=?", (name,)
    ).fetchone()
    return bool(row)


def resolve_projects(con: sqlite3.Connection, project_path: str) -> tuple[list[str], list[str]]:
    """Return (project ids, known worktrees) for a path."""
    wanted = norm_path(project_path)
    rows = con.execute("select id, worktree from project").fetchall()
    matches: list[str] = []
    known: list[str] = []

    for project_id, worktree in rows:
        if not worktree:
            continue
        known.append(str(worktree))
        if norm_path(str(worktree)) == wanted:
            matches.append(str(project_id))

    if table_exists(con, "project_directory"):
        dir_rows = con.execute("select project_id, directory from project_directory").fetchall()
        for project_id, directory in dir_rows:
            if not directory:
                continue
            known.append(str(directory))
            if norm_path(str(directory)) == wanted and str(project_id) not in matches:
                matches.append(str(project_id))

    return matches, sorted(set(known))


def select_sessions(
    con: sqlite3.Connection, project_ids: list[str], all_sessions: bool
) -> list[sqlite3.Row]:
    columns = "id, project_id, title, cost, " + ", ".join(TOKEN_COLUMNS)
    if all_sessions:
        return list(
            con.execute(
                "select %s from session_v2 order by time_updated desc" % columns
            ).fetchall()
        )

    if not project_ids:
        return []

    placeholders = ",".join("?" for _ in project_ids)
    return list(
        con.execute(
            "select %s from session_v2 where project_id in (%s) order by time_updated desc"
            % (columns, placeholders),
            project_ids,
        ).fetchall()
    )


def sum_sessions(rows: list[sqlite3.Row]) -> dict[str, Any]:
    totals: dict[str, Any] = {c: 0 for c in TOKEN_COLUMNS}
    totals["cost"] = 0.0
    for row in rows:
        for column in TOKEN_COLUMNS:
            totals[column] += int(row[column] or 0)
        totals["cost"] += float(row["cost"] or 0)
    return totals


def has_nonzero_usage(data: dict[str, Any]) -> bool:
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        tokens = {}
    cache = tokens.get("cache")
    if not isinstance(cache, dict):
        cache = {}
    values = [
        tokens.get("input", 0),
        tokens.get("output", 0),
        tokens.get("reasoning", 0),
        cache.get("read", 0),
        cache.get("write", 0),
        data.get("cost", 0),
    ]
    for value in values:
        try:
            if float(value or 0) != 0:
                return True
        except (TypeError, ValueError):
            return True
    return False


def zero_message_data(raw: str) -> tuple[str, bool]:
    try:
        data = json.loads(raw)
    except (TypeError, ValueError):
        return raw, False

    if not isinstance(data, dict):
        return raw, False
    if not isinstance(data.get("tokens"), dict) and "cost" not in data:
        return raw, False
    if not has_nonzero_usage(data):
        return raw, False

    data["tokens"] = {
        "input": 0,
        "output": 0,
        "reasoning": 0,
        "cache": {"read": 0, "write": 0},
    }
    data["cost"] = 0
    return json.dumps(data, ensure_ascii=False, separators=(",", ":")), True


def backup_database(db: Path, timeout: int) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_dir = db.with_name(db.name + ".backup-" + stamp)
    counter = 1
    while backup_dir.exists():
        counter += 1
        backup_dir = db.with_name(db.name + ".backup-" + stamp + "-" + str(counter))
    backup_dir.mkdir(parents=True, exist_ok=False)

    backup_db = backup_dir / db.name
    source = connect(db, read_only=True, timeout=timeout)
    target = sqlite3.connect(str(backup_db), timeout=timeout)
    try:
        source.backup(target)
        target.commit()
    finally:
        target.close()
        source.close()

    # Keep the original WAL/SHM beside the consistent backup for forensics.
    for suffix in ("-wal", "-shm"):
        sidecar = db.with_name(db.name + suffix)
        if sidecar.exists():
            try:
                shutil.copy2(sidecar, backup_dir / sidecar.name)
            except OSError:
                pass

    restore = backup_dir / "RESTORE.txt"
    restore.write_text(
        "OpenCode token reset backup\n"
        "===========================\n"
        "Source : %s\n"
        "Created: %s\n\n"
        "The opencode.db in this folder is a consistent online backup.\n"
        "The -wal and -shm files are copies of the original sidecars and are\n"
        "kept for reference only.\n\n"
        "To restore:\n"
        "  1. Close OpenCode completely.\n"
        "  2. In %%USERPROFILE%%\\.local\\share\\opencode, delete opencode.db-wal\n"
        "     and opencode.db-shm if they exist.\n"
        "  3. Copy this folder's opencode.db over the live opencode.db.\n"
        "  4. Start OpenCode.\n"
        % (db, time.strftime("%Y-%m-%d %H:%M:%S"))
    )

    return backup_dir


def zero_pass(
    con: sqlite3.Connection, project_ids: list[str], all_sessions: bool
) -> tuple[int, int]:
    """Zero one scope in a short transaction. Returns (sessions, message rows)."""
    con.execute("BEGIN IMMEDIATE")
    try:
        if all_sessions:
            ids = [str(row["id"]) for row in con.execute("select id from session_v2").fetchall()]
        elif project_ids:
            placeholders = ",".join("?" for _ in project_ids)
            ids = [
                str(row["id"])
                for row in con.execute(
                    "select id from session_v2 where project_id in (%s)" % placeholders,
                    project_ids,
                ).fetchall()
            ]
        else:
            ids = []

        if not ids:
            con.commit()
            return 0, 0

        placeholders = ",".join("?" for _ in ids)
        nonzero = " or ".join([c + " <> 0" for c in TOKEN_COLUMNS] + ["cost <> 0"])
        cursor = con.execute(
            "update session_v2 set cost = 0, %s where id in (%s) and (%s)"
            % (", ".join(c + " = 0" for c in TOKEN_COLUMNS), placeholders, nonzero),
            ids,
        )
        sessions_changed = max(0, int(cursor.rowcount or 0))

        rows = con.execute(
            "select id, data from session_message where session_id in (%s) and data like ?"
            % placeholders,
            ids + ['%"tokens"%'],
        ).fetchall()

        changed_rows = 0
        for message_id, raw in rows:
            new_raw, changed = zero_message_data(raw)
            if changed:
                con.execute(
                    "update session_message set data = ? where id = ?",
                    (new_raw, message_id),
                )
                changed_rows += 1

        con.commit()
        return sessions_changed, changed_rows
    except Exception:
        con.rollback()
        raise


def write_status(path: Path | None, payload: dict[str, Any]) -> None:
    if path is None:
        return
    try:
        payload = dict(payload)
        payload["updated"] = time.strftime("%Y-%m-%d %H:%M:%S")
        payload["pid"] = os.getpid()
        temp = path.with_name(path.name + ".tmp")
        temp.write_text(json.dumps(payload, ensure_ascii=True), encoding="utf-8")
        os.replace(temp, path)
    except OSError:
        pass


def run_watch(
    args: argparse.Namespace, db: Path, project_path: str
) -> int:
    """Keep the stored counters at zero while the old session keeps running."""
    project_ids: list[str] = []
    if not args.all:
        con = connect(db, read_only=True, timeout=args.timeout)
        try:
            project_ids, known = resolve_projects(con, project_path)
            if not project_ids:
                fail("no project matches: " + norm_path(project_path), known=known)
        finally:
            con.close()

    backup_dir = ""
    if args.backup:
        backup_dir = str(backup_database(db, args.timeout))

    status_path = Path(os.path.expandvars(args.status)).resolve() if args.status else None
    deadline = time.monotonic() + args.minutes * 60 if args.minutes > 0 else None
    started = time.strftime("%Y-%m-%d %H:%M:%S")
    scope = "all" if args.all else "project"

    cycles = 0
    sessions_total = 0
    rows_total = 0

    write_status(
        status_path,
        {
            "ok": True,
            "mode": "watch",
            "scope": scope,
            "project": "" if args.all else norm_path(project_path),
            "started": started,
            "interval": args.interval,
            "minutes": args.minutes,
            "backup": backup_dir,
            "cycles": 0,
            "sessions_zeroed": 0,
            "rows_zeroed": 0,
            "last_error": "",
        },
    )

    try:
        while True:
            cycles += 1
            cycle_sessions = 0
            cycle_rows = 0
            error = ""
            try:
                con = connect(db, read_only=False, timeout=min(args.timeout, 5))
                try:
                    cycle_sessions, cycle_rows = zero_pass(con, project_ids, args.all)
                finally:
                    con.close()
            except sqlite3.OperationalError as exc:
                # A busy database is normal while the app is writing; retry next tick.
                error = str(exc)
            except Exception as exc:  # noqa: BLE001
                error = str(exc)

            sessions_total += cycle_sessions
            rows_total += cycle_rows
            write_status(
                status_path,
                {
                    "ok": error == "",
                    "mode": "watch",
                    "scope": scope,
                    "project": "" if args.all else norm_path(project_path),
                    "started": started,
                    "interval": args.interval,
                    "minutes": args.minutes,
                    "backup": backup_dir,
                    "cycles": cycles,
                    "sessions_zeroed": sessions_total,
                    "rows_zeroed": rows_total,
                    "last_error": error,
                },
            )

            if deadline and time.monotonic() >= deadline:
                break
            time.sleep(max(0.5, args.interval))
    except KeyboardInterrupt:
        pass

    write_status(
        status_path,
        {
            "ok": True,
            "mode": "stopped",
            "scope": scope,
            "project": "" if args.all else norm_path(project_path),
            "started": started,
            "stopped": time.strftime("%Y-%m-%d %H:%M:%S"),
            "cycles": cycles,
            "sessions_zeroed": sessions_total,
            "rows_zeroed": rows_total,
            "last_error": "",
        },
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Zero OpenCode token/context counters")
    parser.add_argument("--db", default=str(default_db()), help="path to opencode.db")
    parser.add_argument("--project", default="", help="project directory (default: current directory)")
    parser.add_argument("--all", action="store_true", help="zero every session, not just one project")
    parser.add_argument("--dry-run", action="store_true", help="report only, do not backup or write")
    parser.add_argument("--json", action="store_true", help="emit one JSON object (the default)")
    parser.add_argument("--timeout", type=int, default=30, help="SQLite busy timeout in seconds")
    parser.add_argument("--watch", action="store_true", help="keep counters at zero until stopped")
    parser.add_argument("--interval", type=float, default=3.0, help="watch sleep between passes, seconds")
    parser.add_argument("--minutes", type=float, default=0, help="watch lifetime in minutes (0 = until stopped)")
    parser.add_argument("--backup", action="store_true", help="back up once before watching")
    parser.add_argument("--status", default="", help="write watch status JSON to this path")
    args = parser.parse_args()

    db = Path(os.path.expandvars(os.path.expanduser(args.db))).resolve()
    if not db.exists():
        fail("database not found: " + str(db))

    project_path = args.project or os.getcwd()

    if args.watch:
        try:
            return run_watch(args, db, project_path)
        except SystemExit:
            raise
        except Exception as exc:  # noqa: BLE001
            fail(str(exc), db=str(db))
    project_ids: list[str] = []
    known: list[str] = []

    try:
        con = connect(db, read_only=True, timeout=args.timeout)
        try:
            if not table_exists(con, "session_v2"):
                fail("session_v2 table not found; is this an OpenCode database?", db=str(db))

            if not args.all:
                project_ids, known = resolve_projects(con, project_path)
                if not project_ids:
                    fail(
                        "no project matches: " + norm_path(project_path),
                        known=known,
                    )

            sessions = select_sessions(con, project_ids, args.all)
            session_ids = [str(row["id"]) for row in sessions]
            before = sum_sessions(sessions)

            message_count = 0
            message_usage_rows = 0
            if session_ids:
                placeholders = ",".join("?" for _ in session_ids)
                rows = con.execute(
                    "select id, data from session_message where session_id in (%s)"
                    % placeholders,
                    session_ids,
                ).fetchall()
                message_count = len(rows)
                for _message_id, raw in rows:
                    try:
                        data = json.loads(raw)
                    except (TypeError, ValueError):
                        continue
                    if isinstance(data, dict) and has_nonzero_usage(data):
                        message_usage_rows += 1
        finally:
            con.close()

        scope = "all" if args.all else "project"
        base = {
            "ok": True,
            "dry_run": bool(args.dry_run),
            "db": str(db),
            "scope": scope,
            "project": "" if args.all else norm_path(project_path),
            "project_ids": project_ids,
            "sessions": len(session_ids),
            "session_ids": session_ids,
            "messages": message_count,
            "message_usage_rows": message_usage_rows,
            "before": before,
        }

        if args.dry_run:
            base["would_zero_sessions"] = len(session_ids)
            base["would_zero_message_rows"] = message_usage_rows
            base["backup"] = ""
            emit(base)
            return 0

        if not session_ids:
            base["after"] = before
            base["zeroed_sessions"] = 0
            base["zeroed_message_rows"] = 0
            base["backup"] = ""
            emit(base)
            return 0

        backup_dir = backup_database(db, args.timeout)

        con = connect(db, read_only=False, timeout=args.timeout)
        try:
            con.execute("BEGIN IMMEDIATE")

            placeholders = ",".join("?" for _ in session_ids)
            con.execute(
                "update session_v2 set cost = 0, %s where id in (%s)"
                % (", ".join(c + " = 0" for c in TOKEN_COLUMNS), placeholders),
                session_ids,
            )

            zeroed_messages = 0
            rows = con.execute(
                "select id, data from session_message where session_id in (%s)"
                % placeholders,
                session_ids,
            ).fetchall()
            for message_id, raw in rows:
                new_raw, changed = zero_message_data(raw)
                if changed:
                    con.execute(
                        "update session_message set data = ? where id = ?",
                        (new_raw, message_id),
                    )
                    zeroed_messages += 1

            con.commit()
        except Exception:
            con.rollback()
            raise
        finally:
            con.close()

        # Re-read from the database, not from memory, so the result is verified.
        con = connect(db, read_only=True, timeout=args.timeout)
        try:
            after_sessions = select_sessions(con, project_ids, args.all)
            after = sum_sessions(after_sessions)
            placeholders = ",".join("?" for _ in session_ids)
            rows = con.execute(
                "select data from session_message where session_id in (%s)" % placeholders,
                session_ids,
            ).fetchall()
            remaining_message_usage = 0
            for (raw,) in rows:
                try:
                    data = json.loads(raw)
                except (TypeError, ValueError):
                    continue
                if isinstance(data, dict) and has_nonzero_usage(data):
                    remaining_message_usage += 1
        finally:
            con.close()

        base.update(
            {
                "after": after,
                "zeroed_sessions": len(session_ids),
                "zeroed_message_rows": zeroed_messages,
                "remaining_message_usage_rows": remaining_message_usage,
                "backup": str(backup_dir),
            }
        )

        counters_ok = all(int(after[c] or 0) == 0 for c in TOKEN_COLUMNS) and float(after["cost"] or 0) == 0
        if not counters_ok or remaining_message_usage != 0:
            base["ok"] = False
            base["error"] = "verification failed after write"
            emit(base)
            return 1

        emit(base)
        return 0
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - report a clean JSON error
        fail(str(exc), db=str(db))


if __name__ == "__main__":
    raise SystemExit(main())
