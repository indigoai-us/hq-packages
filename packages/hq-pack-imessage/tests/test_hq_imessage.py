#!/usr/bin/env python3
"""Tests for hq_imessage against a fixture Messages database.

No real Messages data and no real sends: the database is built in a temp dir
with the subset of the chat.db schema the CLI reads, and osascript is replaced
with a recorder.
"""
import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "hq_imessage.py"
SPEC = importlib.util.spec_from_file_location("hq_imessage", SCRIPT)
hq = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(hq)


def typedstream(text: str) -> bytes:
    """Build an attributedBody blob shaped like the ones macOS writes."""
    raw = text.encode("utf-8")
    if len(raw) < 0x80:
        length = bytes([len(raw)])
    elif len(raw) <= 0xFFFF:
        length = b"\x81" + len(raw).to_bytes(2, "little")
    else:
        length = b"\x82" + len(raw).to_bytes(4, "little")
    return (
        b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00"
        b"\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+"
        + length + raw + b"\x86\x84\x02iI\x01\x05\x92\x84\x84\x84\x0cNSDictionary\x00"
    )


def apple_ns(minutes_ago: int) -> int:
    return hq.datetime_to_apple_ns(dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=minutes_ago))


SCHEMA = """
CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, service TEXT);
CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER,
    chat_identifier TEXT, service_name TEXT, display_name TEXT);
CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT,
    handle_id INTEGER DEFAULT 0, attributedBody BLOB, service TEXT, date INTEGER, is_from_me INTEGER DEFAULT 0,
    cache_has_attachments INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0,
    associated_message_type INTEGER DEFAULT 0, thread_originator_guid TEXT);
CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
"""


def build_fixture(path: Path) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    conn.executemany("INSERT INTO handle (ROWID, id, service) VALUES (?, ?, 'iMessage')", [
        (1, "+15551234567"),
        (2, "friend@example.com"),
        (3, "+15559876543"),
    ])
    conn.executemany(
        "INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name) VALUES (?,?,?,?,?,?)",
        [
            (1, "any;-;+15551234567", 45, "+15551234567", "iMessage", ""),
            (2, "any;-;friend@example.com", 45, "friend@example.com", "iMessage", ""),
            (3, "any;+;chat900", 43, "chat900", "iMessage", "Family"),
        ],
    )
    conn.executemany("INSERT INTO chat_handle_join VALUES (?, ?)", [(1, 1), (2, 2), (3, 1), (3, 3)])
    messages = [
        # rowid, chat, handle, text, body, from_me, minutes_ago, assoc_type, attachments
        (1, 1, 1, "old plain text", None, 0, 300, 0, 0),
        (2, 1, 1, None, typedstream("body only in attributedBody"), 0, 200, 0, 0),
        (3, 1, 0, None, typedstream("my reply"), 1, 190, 0, 0),
        (4, 1, 1, None, None, 0, 185, 2000, 0),  # tapback, hidden
        (5, 2, 2, None, typedstream("lunch tomorrow?"), 0, 100, 0, 0),
        (6, 3, 3, None, typedstream("group hello " + "x" * 300), 0, 50, 0, 0),
        (7, 3, 1, "￼", None, 0, 40, 0, 1),  # photo only
    ]
    for rowid, chat, handle, text, body, mine, ago, assoc, att in messages:
        conn.execute(
            """INSERT INTO message (ROWID, guid, text, handle_id, attributedBody, service, date, is_from_me,
               associated_message_type, cache_has_attachments) VALUES (?,?,?,?,?,'iMessage',?,?,?,?)""",
            (rowid, f"G-{rowid}", text, handle, body, apple_ns(ago), mine, assoc, att),
        )
        conn.execute("INSERT INTO chat_message_join VALUES (?, ?)", (chat, rowid))
    conn.commit()
    conn.close()


def add_message(path: Path, rowid: int, chat: int, handle: int, text: str, from_me: int = 0) -> None:
    conn = sqlite3.connect(path)
    conn.execute(
        """INSERT INTO message (ROWID, guid, text, handle_id, attributedBody, service, date, is_from_me)
           VALUES (?,?,NULL,?,?,'iMessage',?,?)""",
        (rowid, f"G-{rowid}", handle, typedstream(text), apple_ns(0), from_me),
    )
    conn.execute("INSERT INTO chat_message_join VALUES (?, ?)", (chat, rowid))
    conn.commit()
    conn.close()


def run_cli(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = hq.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.db = root / "chat.db"
        build_fixture(self.db)
        self.env = mock.patch.dict(os.environ, {
            "HQ_IMESSAGE_DB": str(self.db),
            "HQ_IMESSAGE_STATE_DIR": str(root / "state"),
        })
        self.env.start()
        for key in ("HQ_UNATTENDED", "HQ_SESSION_UNATTENDED", "HQ_IMESSAGE_REQUIRE_ALLOWLIST",
                    "HQ_IMESSAGE_ALLOW_FILE"):
            os.environ.pop(key, None)

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()


class DecodeTests(unittest.TestCase):
    def test_short_medium_and_unicode_bodies(self):
        for text in ("hi", "y" * 200, "z" * 70000, "café 👋"):
            self.assertEqual(hq.decode_attributed_body(typedstream(text)), text)

    def test_garbage_and_empty(self):
        self.assertIsNone(hq.decode_attributed_body(None))
        self.assertIsNone(hq.decode_attributed_body(b"no marker here"))
        self.assertIsNone(hq.decode_attributed_body(typedstream("￼")))
        truncated = typedstream("hello world")[:-30]
        self.assertIsNone(hq.decode_attributed_body(truncated))

    def test_apple_time_units(self):
        self.assertEqual(hq.apple_time_to_datetime(0), None)
        seconds = hq.apple_time_to_datetime(86400)
        nanos = hq.apple_time_to_datetime(86400 * 10**9)
        self.assertEqual(seconds, nanos)
        self.assertEqual(seconds.year, 2001)


class ReadTests(Base):
    def test_read_by_phone_formats_hides_tapbacks_and_decodes(self):
        code, out, _ = run_cli("read", "(555) 123-4567", "--json")
        self.assertEqual(code, 0)
        msgs = json.loads(out)
        self.assertEqual([m["text"] for m in msgs],
                         ["old plain text", "body only in attributedBody", "my reply"])
        self.assertEqual(msgs[-1]["sender"], "me")
        # A phone number reads the 1:1 chat, not the group that person is in.
        self.assertTrue(all(not m["group"] for m in msgs))

    def test_read_group_by_name_and_limit(self):
        code, out, _ = run_cli("read", "Family", "1", "--json")
        self.assertEqual(code, 0)
        msgs = json.loads(out)
        self.assertEqual(len(msgs), 1)
        self.assertTrue(msgs[0]["has_attachments"])
        self.assertIsNone(msgs[0]["text"])

    def test_read_email_case_insensitive(self):
        code, out, _ = run_cli("read", "Friend@Example.com", "--json")
        self.assertEqual(json.loads(out)[0]["text"], "lunch tomorrow?")

    def test_read_unknown_target_fails_plainly(self):
        code, _, err = run_cli("read", "+19990000000")
        self.assertEqual(code, 1)
        self.assertIn("No chat found", err)

    def test_chats_ordered_newest_first_with_query(self):
        code, out, _ = run_cli("chats", "--json")
        chats = json.loads(out)
        self.assertEqual([c["name"] for c in chats], ["Family", "friend@example.com", "+15551234567"])
        self.assertEqual(chats[0]["members"], ["+15551234567", "+15559876543"])
        code, out, _ = run_cli("chats", "--query", "friend", "--json")
        self.assertEqual(len(json.loads(out)), 1)

    def test_search_finds_attributed_body_text(self):
        code, out, _ = run_cli("search", "LUNCH", "--json")
        self.assertEqual([m["id"] for m in json.loads(out)], [5])

    def test_recent_incoming_only(self):
        code, out, _ = run_cli("recent", "10", "--incoming", "--json")
        self.assertNotIn(3, [m["id"] for m in json.loads(out)])

    def test_missing_database(self):
        os.environ["HQ_IMESSAGE_DB"] = str(Path(self.tmp.name) / "nope.db")
        code, _, err = run_cli("recent")
        self.assertEqual(code, 2)
        self.assertIn("No Messages database", err)


class WatchTests(Base):
    def test_first_run_starts_now_then_streams_only_new_incoming(self):
        code, out, _ = run_cli("watch", "--once", "--name", "bot-a")
        self.assertEqual((code, out), (0, ""))
        add_message(self.db, 8, 2, 2, "are you there?")
        add_message(self.db, 9, 2, 0, "my own reply", from_me=1)
        code, out, _ = run_cli("watch", "--once", "--name", "bot-a")
        lines = [json.loads(l) for l in out.splitlines()]
        self.assertEqual([(m["id"], m["text"]) for m in lines], [(8, "are you there?")])
        # Cursor moved past both rows, so nothing repeats.
        code, out, _ = run_cli("watch", "--once", "--name", "bot-a")
        self.assertEqual(out, "")

    def test_cursors_are_per_bot(self):
        run_cli("watch", "--once", "--name", "bot-a")
        add_message(self.db, 8, 2, 2, "ping")
        _, out_a, _ = run_cli("watch", "--once", "--name", "bot-a")
        _, out_b, _ = run_cli("watch", "--once", "--name", "bot-b", "--from-start")
        self.assertEqual(len(out_a.splitlines()), 1)
        self.assertGreater(len(out_b.splitlines()), 1)


class SendTests(Base):
    def test_text_goes_in_argv_not_script_source(self):
        hostile = 'hi" & (do shell script "touch /tmp/pwned") & "'
        calls = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            add_message(self.db, 50, 1, 0, hostile, from_me=1)
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(hq.subprocess, "run", side_effect=fake_run):
            code, out, _ = run_cli("send", "+15551234567", hostile, "--verify-seconds", "0")
        self.assertEqual(code, 0)
        cmd = calls[0]
        self.assertEqual(cmd[:2], ["osascript", "-e"])
        self.assertNotIn(hostile, cmd[2])
        self.assertEqual(cmd[3:], ["+15551234567", hostile, "iMessage"])
        self.assertTrue(json.loads(out)["confirmed_in_history"])

    def test_group_name_resolves_to_chat_id(self):
        code, out, _ = run_cli("send", "Family", "hello all", "--dry-run")
        self.assertEqual(json.loads(out)["argv"], ["any;+;chat900", "hello all"])

    def test_empty_message_refused(self):
        code, _, err = run_cli("send", "+15551234567", "   ", "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("empty", err)

    def test_unknown_group_name_refused(self):
        code, _, err = run_cli("send", "Nobody Group", "hi", "--dry-run")
        self.assertEqual(code, 1)

    def test_automation_denied_gives_permission_hint(self):
        denied = mock.Mock(returncode=1, stdout="", stderr="Not authorized to send Apple events to Messages. (-1743)")
        with mock.patch.object(hq.subprocess, "run", return_value=denied):
            code, _, err = run_cli("send", "+15551234567", "hi")
        self.assertEqual(code, 5)
        self.assertIn("Automation", err)

    def test_send_file_requires_existing_file(self):
        code, _, err = run_cli("send-file", "+15551234567", "/no/such/file.png", "--dry-run")
        self.assertEqual(code, 1)
        photo = Path(self.tmp.name) / "p.png"
        photo.write_bytes(b"png")
        code, out, _ = run_cli("send-file", "+15551234567", str(photo), "--dry-run")
        self.assertEqual(json.loads(out)["argv"], ["+15551234567", str(photo.resolve()), "iMessage"])


class AllowlistTests(Base):
    def test_unattended_send_blocked_until_allowed(self):
        os.environ["HQ_UNATTENDED"] = "1"
        code, _, err = run_cli("send", "+15551234567", "hi", "--dry-run")
        self.assertEqual(code, 4)
        self.assertIn("allowlist", err)
        # Formatting differences don't matter for phone numbers.
        run_cli("allow", "add", "555-123-4567")
        code, _, _ = run_cli("send", "+1 (555) 123-4567", "hi", "--dry-run")
        self.assertEqual(code, 0)
        code, _, _ = run_cli("send", "+15559876543", "hi", "--dry-run")
        self.assertEqual(code, 4)
        run_cli("allow", "remove", "+15551234567")
        code, _, _ = run_cli("send", "+15551234567", "hi", "--dry-run")
        self.assertEqual(code, 4)

    def test_group_send_needs_chat_id_on_allowlist(self):
        os.environ["HQ_UNATTENDED"] = "1"
        run_cli("allow", "add", "any;+;chat900")
        code, _, _ = run_cli("send", "Family", "hi", "--dry-run")
        self.assertEqual(code, 0)

    def test_interactive_send_not_gated(self):
        code, _, _ = run_cli("send", "+15559876543", "hi", "--dry-run")
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
