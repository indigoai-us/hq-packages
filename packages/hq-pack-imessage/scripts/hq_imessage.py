#!/usr/bin/env python3
"""hq-imessage: read and send iMessages from this Mac's own Messages account.

Reads come straight from the Messages database (~/Library/Messages/chat.db,
opened read-only). Sends go through Messages.app via AppleScript, with the
recipient and text passed as osascript arguments, never spliced into script
source.

Stdlib only. Runs on macOS; the read/parse logic is portable so the test suite
runs anywhere against a fixture database.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_DB = Path.home() / "Library" / "Messages" / "chat.db"

# Messages stores dates as time since 2001-01-01 UTC. Since macOS 10.13 the
# unit is nanoseconds; older rows use seconds.
APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)

# associated_message_type 2000-3999 are tapbacks (reactions) and their
# removals. They are not messages a reader wants to see as text.
TAPBACK_MIN, TAPBACK_MAX = 2000, 3999

# chat.style 43 is a group chat; 45 is a one-to-one chat.
GROUP_STYLE = 43

SEND_SCRIPT_BUDDY = """
on run argv
    set targetHandle to item 1 of argv
    set messageText to item 2 of argv
    set serviceName to item 3 of argv
    tell application "Messages"
        if serviceName is "SMS" then
            set targetService to 1st account whose service type = SMS
        else
            set targetService to 1st account whose service type = iMessage
        end if
        set targetBuddy to participant targetHandle of targetService
        send messageText to targetBuddy
    end tell
end run
"""

SEND_SCRIPT_CHAT = """
on run argv
    set chatGuid to item 1 of argv
    set messageText to item 2 of argv
    tell application "Messages"
        send messageText to chat id chatGuid
    end tell
end run
"""

SEND_FILE_SCRIPT_BUDDY = """
on run argv
    set targetHandle to item 1 of argv
    set filePath to item 2 of argv
    set serviceName to item 3 of argv
    tell application "Messages"
        if serviceName is "SMS" then
            set targetService to 1st account whose service type = SMS
        else
            set targetService to 1st account whose service type = iMessage
        end if
        set targetBuddy to participant targetHandle of targetService
        send (POSIX file filePath) to targetBuddy
    end tell
end run
"""

SEND_FILE_SCRIPT_CHAT = """
on run argv
    set chatGuid to item 1 of argv
    set filePath to item 2 of argv
    tell application "Messages"
        send (POSIX file filePath) to chat id chatGuid
    end tell
end run
"""


class CliError(Exception):
    """A user-facing failure with a plain message and an exit code."""

    def __init__(self, message: str, code: int = 1):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------------------
# Paths (read from the environment at call time so tests can redirect them)
# ---------------------------------------------------------------------------

def db_path() -> Path:
    return Path(os.environ.get("HQ_IMESSAGE_DB", DEFAULT_DB))


def state_dir() -> Path:
    return Path(os.environ.get("HQ_IMESSAGE_STATE_DIR", Path.home() / ".hq" / "imessage"))


def allow_file() -> Path:
    return Path(os.environ.get("HQ_IMESSAGE_ALLOW_FILE", state_dir() / "allow.txt"))


# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------

def apple_time_to_datetime(value: int | None) -> dt.datetime | None:
    if not value:
        return None
    seconds = value / 1_000_000_000 if abs(value) > 10**11 else value
    return APPLE_EPOCH + dt.timedelta(seconds=seconds)


def datetime_to_apple_ns(when: dt.datetime) -> int:
    delta = when.astimezone(dt.timezone.utc) - APPLE_EPOCH
    return int(delta.total_seconds() * 1_000_000_000)


def decode_attributed_body(blob: bytes | None) -> str | None:
    """Pull the plain string out of an NSAttributedString typedstream blob.

    Recent macOS versions leave message.text NULL and keep the body only in
    attributedBody. The archived NSString content follows the class name, a
    '+' type marker, and a typedstream-encoded length: one byte, or 0x81
    followed by a little-endian uint16, or 0x82 followed by a uint32.
    """
    if not blob:
        return None
    anchor = blob.find(b"NSString")
    if anchor < 0:
        return None
    plus = blob.find(b"+", anchor + len(b"NSString"))
    if plus < 0:
        return None
    pos = plus + 1
    if pos >= len(blob):
        return None
    length = blob[pos]
    pos += 1
    if length == 0x81:
        length = int.from_bytes(blob[pos:pos + 2], "little")
        pos += 2
    elif length == 0x82:
        length = int.from_bytes(blob[pos:pos + 4], "little")
        pos += 4
    raw = blob[pos:pos + length]
    if len(raw) != length:
        return None
    text = raw.decode("utf-8", errors="replace")
    # U+FFFC is the attachment placeholder character.
    return text.replace("￼", "").strip() or None


def message_text(text: str | None, attributed: bytes | None) -> str | None:
    if text:
        return text.replace("￼", "").strip() or None
    return decode_attributed_body(attributed)


def digits_only(value: str) -> str:
    return re.sub(r"\D", "", value)


def is_phone_like(value: str) -> bool:
    return "@" not in value and ";" not in value and len(digits_only(value)) >= 7 \
        and not re.search(r"[A-Za-z]", value)


# ---------------------------------------------------------------------------
# Database access
# ---------------------------------------------------------------------------

def connect() -> sqlite3.Connection:
    path = db_path()
    if not path.exists():
        raise CliError(
            f"No Messages database at {path}. Sign in to Messages on this Mac first.",
            code=2,
        )
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        conn.execute("SELECT 1 FROM message LIMIT 1")
    except sqlite3.OperationalError as exc:
        raise CliError(
            "Can't open the Messages database. Give the app running this command "
            "Full Disk Access (System Settings > Privacy & Security > Full Disk Access), "
            f"then try again. Detail: {exc}",
            code=3,
        ) from exc
    return conn


MESSAGE_COLUMNS = """
    m.ROWID AS rowid, m.guid AS guid, m.text AS text, m.attributedBody AS body,
    m.date AS date, m.is_from_me AS is_from_me, m.service AS service,
    m.cache_has_attachments AS has_attachments,
    m.thread_originator_guid AS reply_to,
    h.id AS handle,
    c.guid AS chat_guid, c.chat_identifier AS chat_identifier,
    c.display_name AS chat_name, c.style AS chat_style
"""

MESSAGE_FROM = """
    FROM message m
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    LEFT JOIN chat c ON c.ROWID = cmj.chat_id
"""

TEXTUAL_FILTER = (
    "(m.associated_message_type IS NULL OR m.associated_message_type NOT BETWEEN "
    f"{TAPBACK_MIN} AND {TAPBACK_MAX}) AND (m.item_type IS NULL OR m.item_type = 0)"
)


def row_to_message(row: sqlite3.Row) -> dict:
    when = apple_time_to_datetime(row["date"])
    return {
        "id": row["rowid"],
        "guid": row["guid"],
        "time": when.isoformat() if when else None,
        "from_me": bool(row["is_from_me"]),
        "sender": "me" if row["is_from_me"] else (row["handle"] or "unknown"),
        "text": message_text(row["text"], row["body"]),
        "has_attachments": bool(row["has_attachments"]),
        "service": row["service"],
        "chat": row["chat_guid"],
        "chat_name": row["chat_name"] or row["chat_identifier"],
        "group": row["chat_style"] == GROUP_STYLE,
        "reply_to": row["reply_to"],
    }


def resolve_chat_ids(conn: sqlite3.Connection, target: str) -> list[int]:
    """Map a phone number, email, chat id, or group name to chat ROWIDs."""
    rows = conn.execute(
        "SELECT ROWID FROM chat WHERE guid = ? OR chat_identifier = ? OR display_name = ?",
        (target, target, target),
    ).fetchall()
    if rows:
        return [r[0] for r in rows]

    if is_phone_like(target):
        tail = digits_only(target)[-10:]
        handle_ids = [
            r[0] for r in conn.execute("SELECT ROWID, id FROM handle").fetchall()
            if digits_only(r[1] or "").endswith(tail)
        ]
    else:
        handle_ids = [
            r[0] for r in conn.execute(
                "SELECT ROWID FROM handle WHERE lower(id) = lower(?)", (target,)
            ).fetchall()
        ]
    if not handle_ids:
        return []
    marks = ",".join("?" * len(handle_ids))
    # One-to-one chats only: a phone number or email names a person, not
    # every group that person is in.
    rows = conn.execute(
        f"""SELECT DISTINCT chj.chat_id FROM chat_handle_join chj
            JOIN chat c ON c.ROWID = chj.chat_id
            WHERE chj.handle_id IN ({marks}) AND (c.style IS NULL OR c.style != {GROUP_STYLE})""",
        handle_ids,
    ).fetchall()
    return [r[0] for r in rows]


def list_chats(conn: sqlite3.Connection, limit: int, query: str | None) -> list[dict]:
    rows = conn.execute(
        """SELECT c.ROWID AS chat_rowid, c.guid AS chat_guid, c.chat_identifier,
                  c.display_name, c.style, c.service_name,
                  MAX(m.date) AS last_date
           FROM chat c
           JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
           JOIN message m ON m.ROWID = cmj.message_id
           GROUP BY c.ROWID
           ORDER BY last_date DESC"""
    ).fetchall()
    chats = []
    for row in rows:
        members = [
            r[0] for r in conn.execute(
                """SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
                   WHERE chj.chat_id = ? ORDER BY h.id""",
                (row["chat_rowid"],),
            ).fetchall()
        ]
        name = row["display_name"] or row["chat_identifier"]
        if query:
            haystack = " ".join([name or "", row["chat_guid"] or "", *members]).lower()
            if query.lower() not in haystack:
                continue
        when = apple_time_to_datetime(row["last_date"])
        chats.append({
            "chat": row["chat_guid"],
            "name": name,
            "group": row["style"] == GROUP_STYLE,
            "members": members,
            "service": row["service_name"],
            "last_message": when.isoformat() if when else None,
        })
        if len(chats) >= limit:
            break
    return chats


def read_messages(conn: sqlite3.Connection, target: str, limit: int) -> list[dict]:
    chat_ids = resolve_chat_ids(conn, target)
    if not chat_ids:
        raise CliError(f"No chat found for '{target}'. Try `chats --query {target}`.")
    marks = ",".join("?" * len(chat_ids))
    rows = conn.execute(
        f"""SELECT {MESSAGE_COLUMNS} {MESSAGE_FROM}
            WHERE cmj.chat_id IN ({marks}) AND {TEXTUAL_FILTER}
            ORDER BY m.date DESC LIMIT ?""",
        (*chat_ids, limit),
    ).fetchall()
    return [row_to_message(r) for r in reversed(rows)]


def recent_messages(conn: sqlite3.Connection, limit: int, incoming_only: bool) -> list[dict]:
    where = TEXTUAL_FILTER + (" AND m.is_from_me = 0" if incoming_only else "")
    rows = conn.execute(
        f"SELECT {MESSAGE_COLUMNS} {MESSAGE_FROM} WHERE {where} ORDER BY m.date DESC LIMIT ?",
        (limit,),
    ).fetchall()
    return [row_to_message(r) for r in reversed(rows)]


def search_messages(conn: sqlite3.Connection, query: str, limit: int, days: int) -> list[dict]:
    # attributedBody can't be filtered in SQL, so scan a date-bounded window
    # newest first and stop once enough matches are found.
    since = datetime_to_apple_ns(dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days))
    cursor = conn.execute(
        f"""SELECT {MESSAGE_COLUMNS} {MESSAGE_FROM}
            WHERE {TEXTUAL_FILTER} AND m.date >= ?
            ORDER BY m.date DESC""",
        (since,),
    )
    needle = query.lower()
    hits = []
    for row in cursor:
        msg = row_to_message(row)
        if msg["text"] and needle in msg["text"].lower():
            hits.append(msg)
            if len(hits) >= limit:
                break
    return list(reversed(hits))


def max_rowid(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COALESCE(MAX(ROWID), 0) FROM message").fetchone()[0]


def messages_after(conn: sqlite3.Connection, after_rowid: int, incoming_only: bool) -> list[dict]:
    where = f"m.ROWID > ? AND {TEXTUAL_FILTER}" + (" AND m.is_from_me = 0" if incoming_only else "")
    rows = conn.execute(
        f"SELECT {MESSAGE_COLUMNS} {MESSAGE_FROM} WHERE {where} ORDER BY m.ROWID ASC",
        (after_rowid,),
    ).fetchall()
    return [row_to_message(r) for r in rows]


# ---------------------------------------------------------------------------
# Sending
# ---------------------------------------------------------------------------

def load_allowlist() -> set[str]:
    path = allow_file()
    if not path.exists():
        return set()
    entries = set()
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            entries.add(line)
    return entries


def allow_key(value: str) -> str:
    return digits_only(value)[-10:] if is_phone_like(value) else value.lower()


def unattended() -> bool:
    return any(
        os.environ.get(k)
        for k in ("HQ_UNATTENDED", "HQ_SESSION_UNATTENDED", "HQ_IMESSAGE_REQUIRE_ALLOWLIST")
    )


def check_allowed(target: str) -> None:
    """Unattended callers (local bots, scheduled jobs) may only send to the allowlist."""
    if not unattended():
        return
    allowed = {allow_key(e) for e in load_allowlist()}
    if allow_key(target) not in allowed:
        raise CliError(
            f"Refusing to send to '{target}': unattended sends are limited to the allowlist "
            f"at {allow_file()}. Ask the owner to add it with `hq-imessage.sh allow add {target}`.",
            code=4,
        )


def is_chat_guid(target: str) -> bool:
    return ";" in target and target.split(";", 1)[0] in {"iMessage", "SMS", "RCS", "any"}


def build_send_command(target: str, payload: str, service: str, is_file: bool) -> list[str]:
    if is_chat_guid(target):
        script = SEND_FILE_SCRIPT_CHAT if is_file else SEND_SCRIPT_CHAT
        return ["osascript", "-e", script, target, payload]
    script = SEND_FILE_SCRIPT_BUDDY if is_file else SEND_SCRIPT_BUDDY
    return ["osascript", "-e", script, target, payload, service]


def run_send(command: list[str]) -> None:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    except FileNotFoundError as exc:
        raise CliError("osascript not found. Sending only works on macOS.", code=2) from exc
    except subprocess.TimeoutExpired as exc:
        raise CliError("Messages did not respond within 60 seconds.", code=5) from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        hint = ""
        if "-1743" in detail or "Not authorized" in detail:
            hint = " Allow this app to control Messages in System Settings > Privacy & Security > Automation."
        raise CliError(f"Messages refused the send.{hint} Detail: {detail}", code=5)


def resolve_send_target(conn: sqlite3.Connection | None, target: str) -> str:
    """Group names resolve to their chat id so a bot can say `send "Family" ...`."""
    if is_chat_guid(target) or is_phone_like(target) or "@" in target or conn is None:
        return target
    row = conn.execute(
        "SELECT guid FROM chat WHERE display_name = ? OR chat_identifier = ?", (target, target)
    ).fetchone()
    if row is None:
        raise CliError(f"'{target}' is not a phone number, email, or known group name.")
    return row["guid"]


def verify_sent(conn: sqlite3.Connection, before_rowid: int, text: str, wait_seconds: float) -> bool:
    deadline = time.monotonic() + wait_seconds
    while True:
        for msg in messages_after(conn, before_rowid, incoming_only=False):
            if msg["from_me"] and (msg["text"] or "").strip() == text.strip():
                return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.5)


# ---------------------------------------------------------------------------
# Watch cursor
# ---------------------------------------------------------------------------

def cursor_path(name: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", name)
    return state_dir() / f"cursor-{safe}.json"


def load_cursor(name: str) -> int | None:
    path = cursor_path(name)
    if not path.exists():
        return None
    return int(json.loads(path.read_text())["rowid"])


def save_cursor(name: str, rowid: int) -> None:
    path = cursor_path(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps({"rowid": rowid, "saved": dt.datetime.now(dt.timezone.utc).isoformat()}))
    tmp.replace(path)


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def emit(items, as_json: bool, formatter) -> None:
    if as_json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
        return
    for item in items:
        print(formatter(item))


def fmt_message(msg: dict) -> str:
    when = (msg["time"] or "")[:16].replace("T", " ")
    where = f" [{msg['chat_name']}]" if msg["group"] else ""
    body = msg["text"] or ("(attachment)" if msg["has_attachments"] else "(no text)")
    return f"{when}  {msg['sender']}{where}: {body}"


def fmt_chat(chat: dict) -> str:
    when = (chat["last_message"] or "")[:16].replace("T", " ")
    kind = "group" if chat["group"] else "1:1"
    members = ", ".join(chat["members"][:6])
    return f"{when}  {chat['name']}  ({kind}; {members})  id={chat['chat']}"


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_doctor(args) -> int:
    ok = True
    report = {"platform": sys.platform, "database": str(db_path())}
    try:
        conn = connect()
        report["database_readable"] = True
        report["message_count"] = conn.execute("SELECT COUNT(*) FROM message").fetchone()[0]
        conn.close()
    except CliError as exc:
        ok = False
        report["database_readable"] = False
        report["database_error"] = str(exc)
    if sys.platform == "darwin":
        probe = subprocess.run(
            # Same lookup the send script uses. "every account" can fail with
            # -10000 when one account is in a bad state, so don't probe that.
            ["osascript", "-e",
             'tell application "Messages" to get id of (1st account whose service type = iMessage)'],
            capture_output=True, text=True, timeout=30,
        )
        report["messages_automation"] = probe.returncode == 0
        if probe.returncode != 0:
            ok = False
            report["automation_error"] = probe.stderr.strip()
    else:
        ok = False
        report["messages_automation"] = False
        report["automation_error"] = "Sending needs macOS."
    report["allowlist_file"] = str(allow_file())
    report["allowlist_entries"] = len(load_allowlist())
    report["unattended_mode"] = unattended()
    print(json.dumps(report, indent=2))
    return 0 if ok else 1


def cmd_chats(args) -> int:
    with contextlib.closing(connect()) as conn:
        emit(list_chats(conn, args.limit, args.query), args.json, fmt_chat)
    return 0


def cmd_read(args) -> int:
    with contextlib.closing(connect()) as conn:
        emit(read_messages(conn, args.target, args.limit), args.json, fmt_message)
    return 0


def cmd_recent(args) -> int:
    with contextlib.closing(connect()) as conn:
        emit(recent_messages(conn, args.limit, args.incoming), args.json, fmt_message)
    return 0


def cmd_search(args) -> int:
    with contextlib.closing(connect()) as conn:
        emit(search_messages(conn, args.query, args.limit, args.days), args.json, fmt_message)
    return 0


def cmd_send(args) -> int:
    conn = None
    try:
        conn = connect()
    except CliError:
        # A dry run of a plain phone/email send doesn't need the database.
        if not args.dry_run:
            raise
    target = resolve_send_target(conn, args.target)
    check_allowed(target)
    if args.is_file:
        path = Path(args.path).expanduser().resolve()
        if not path.is_file():
            raise CliError(f"No file at {path}.")
        payload = str(path)
    else:
        payload = args.text
        if not payload.strip():
            raise CliError("Refusing to send an empty message.")
    command = build_send_command(target, payload, args.service, args.is_file)
    if args.dry_run:
        if conn is not None:
            conn.close()
        print(json.dumps({"dry_run": True, "target": target, "argv": command[3:]}, ensure_ascii=False))
        return 0
    with contextlib.closing(conn):
        before = max_rowid(conn)
        run_send(command)
        confirmed = (not args.is_file) and verify_sent(conn, before, payload, args.verify_seconds)
    print(json.dumps({"sent": True, "target": target, "confirmed_in_history": confirmed}))
    return 0


def cmd_watch(args) -> int:
    with contextlib.closing(connect()) as conn:
        return watch_loop(conn, args)


def watch_loop(conn: sqlite3.Connection, args) -> int:
    cursor = load_cursor(args.name)
    if cursor is None:
        # First run starts at "now" so a bot does not answer years of history.
        cursor = 0 if args.from_start else max_rowid(conn)
        save_cursor(args.name, cursor)
    while True:
        batch = messages_after(conn, cursor, incoming_only=not args.include_mine)
        new_cursor = max(cursor, max_rowid(conn))
        for msg in batch:
            print(json.dumps(msg, ensure_ascii=False), flush=True)
        if new_cursor != cursor:
            cursor = new_cursor
            save_cursor(args.name, cursor)
        if args.once:
            return 0
        time.sleep(args.interval)


def cmd_allow(args) -> int:
    entries = load_allowlist()
    if args.action == "list":
        for entry in sorted(entries):
            print(entry)
        return 0
    if not args.handle:
        raise CliError("Give a phone number, email, or chat id.")
    if args.action == "add":
        entries.add(args.handle)
    else:
        key = allow_key(args.handle)
        entries = {e for e in entries if allow_key(e) != key}
    path = allow_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{e}\n" for e in sorted(entries)))
    print(f"{args.action}: {args.handle} ({len(entries)} allowed)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="hq-imessage", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("doctor", help="Check database access and Messages automation permission")
    p.set_defaults(handler=cmd_doctor)

    p = sub.add_parser("chats", help="List recent conversations")
    p.add_argument("--limit", type=int, default=20)
    p.add_argument("--query", help="Filter by name, member, or chat id")
    p.add_argument("--json", action="store_true")
    p.set_defaults(handler=cmd_chats)

    p = sub.add_parser("read", help="Read a conversation (phone, email, chat id, or group name)")
    p.add_argument("target")
    p.add_argument("limit", nargs="?", type=int, default=20)
    p.add_argument("--json", action="store_true")
    p.set_defaults(handler=cmd_read)

    p = sub.add_parser("recent", help="Latest messages across all chats")
    p.add_argument("limit", nargs="?", type=int, default=20)
    p.add_argument("--incoming", action="store_true", help="Only messages from other people")
    p.add_argument("--json", action="store_true")
    p.set_defaults(handler=cmd_recent)

    p = sub.add_parser("search", help="Search message text")
    p.add_argument("query")
    p.add_argument("--limit", type=int, default=20)
    p.add_argument("--days", type=int, default=365)
    p.add_argument("--json", action="store_true")
    p.set_defaults(handler=cmd_search)

    for name, is_file in (("send", False), ("send-file", True)):
        p = sub.add_parser(name, help="Send a file" if is_file else "Send a message")
        p.add_argument("target", help="Phone number, email, chat id, or group name")
        p.add_argument("path" if is_file else "text")
        p.add_argument("--service", choices=["iMessage", "SMS"], default="iMessage")
        p.add_argument("--dry-run", action="store_true", help="Show what would be sent without sending")
        p.add_argument("--verify-seconds", type=float, default=5.0)
        p.set_defaults(handler=cmd_send, is_file=is_file)

    p = sub.add_parser("watch", help="Stream new messages as JSON lines (for bots)")
    p.add_argument("--name", default="default", help="Cursor name; use one per bot")
    p.add_argument("--interval", type=float, default=3.0)
    p.add_argument("--once", action="store_true", help="Print what is new since the last run, then exit")
    p.add_argument("--include-mine", action="store_true")
    p.add_argument("--from-start", action="store_true", help="First run replays all history")
    p.set_defaults(handler=cmd_watch)

    p = sub.add_parser("allow", help="Manage who unattended bots may message")
    p.add_argument("action", choices=["list", "add", "remove"])
    p.add_argument("handle", nargs="?")
    p.set_defaults(handler=cmd_allow)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.handler(args)
    except CliError as exc:
        print(f"hq-imessage: {exc}", file=sys.stderr)
        return exc.code
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
