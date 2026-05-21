#!/usr/bin/env python3
"""Filter a Slack search.messages response down to @-mentions of a
specific bot in messages newer than --last-ts.

Mirrors parse-mentions.py but for the search.messages payload shape
(`messages.matches[]` with embedded `channel.id`), so the watcher can
discover in-thread @-mentions of the bot anywhere in the workspace —
including reply mentions inside threads whose parent message predates
the watcher's arm time and therefore never appears in conversations.history.

Usage:

    curl ...search.messages?query=...&sort=timestamp&sort_dir=desc... \\
      | parse-search.py --last-ts "$LAST_TS" --bot "$BOT_USER_ID"

Output:

    OK=<true|false>
    ERR=<error-string-or-empty>
    MAX_TS=<numeric-or-empty>
    <blank line>
    M\\t<ts>\\t<channel>\\t<user>\\t<thread_ts>\\t<text>   (ascending ts)

The search-side query (`<@BOT_USER_ID>`) gets the candidate set; this
parser double-checks the literal `<@BOT>` token in the message text to
drop fuzzy / synonym matches. Skips messages authored by the bot itself
(e.g. the bot quoting its own earlier response).
"""

import argparse
import json
import sys


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--last-ts", required=True, help="cursor, numeric")
    p.add_argument("--bot", required=True, help="bot user id whose @-mention we filter for")
    args = p.parse_args()

    decoder = json.JSONDecoder(strict=False)
    try:
        raw = sys.stdin.read()
        data = decoder.decode(raw)
    except (json.JSONDecodeError, ValueError) as e:
        print("OK=false")
        print(f"ERR=parse_error:{type(e).__name__}")
        print("MAX_TS=")
        return 0

    ok = bool(data.get("ok"))
    err = data.get("error") or ""
    matches = ((data.get("messages") or {}).get("matches")) or []

    try:
        last = float(args.last_ts)
    except (ValueError, TypeError):
        last = 0.0

    token = f"<@{args.bot}>"
    rows = []
    max_ts: float | None = None
    for m in matches:
        ts_str = m.get("ts") or ""
        try:
            ts_num = float(ts_str)
        except ValueError:
            continue
        if max_ts is None or ts_num > max_ts:
            max_ts = ts_num
        if ts_num <= last:
            continue

        # Search index can lag behind message_changed/message_deleted; drop
        # anything that looks like a non-user message body.
        subtype = m.get("subtype") or ""
        if subtype in {"message_changed", "message_deleted", "bot_message", "channel_join", "channel_leave"}:
            continue

        author = m.get("user") or m.get("bot_id") or ""
        if author == args.bot:
            continue

        text = m.get("text") or ""
        if token not in text:
            continue

        channel = ""
        ch_obj = m.get("channel")
        if isinstance(ch_obj, dict):
            channel = ch_obj.get("id") or ""
        if not channel:
            continue

        # For thread replies, thread_ts is the canonical thread parent ts.
        # For top-level posts, the result item has no thread_ts and the
        # message ts IS the thread parent.
        thread_ts = m.get("thread_ts") or ts_str
        clean_text = text.replace("\n", " ").replace("\r", " ")
        rows.append((ts_num, ts_str, channel, author, thread_ts, clean_text))

    rows.sort(key=lambda r: r[0])

    print(f"OK={'true' if ok else 'false'}")
    print(f"ERR={err}")
    print(f"MAX_TS={max_ts if max_ts is not None else ''}")
    print("")
    for _, ts_str, channel, user, thread_ts, text in rows:
        print(f"M\t{ts_str}\t{channel}\t{user}\t{thread_ts}\t{text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
