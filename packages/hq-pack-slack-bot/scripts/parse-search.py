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

        # Resolve the canonical thread parent ts. Slack's search.messages
        # response is bizarre here: the top-level `thread_ts` field is
        # often null even when the match IS a thread reply — but the
        # `permalink` URL embeds the real thread_ts as a query param.
        # Fall back to the message's own ts only for genuine top-level
        # mentions (no thread membership).
        #
        # Without the permalink extraction, a reply mention spawns a
        # worker whose poll-thread.py watches a non-existent thread
        # (keyed on the reply's own ts, which isn't a thread parent),
        # so subsequent in-thread follow-ups never reach the worker.
        thread_ts = m.get("thread_ts")
        if not thread_ts:
            permalink = m.get("permalink") or ""
            # Extract `thread_ts=<...>` from the URL's query string.
            # Don't trust full URL parsing libs here — the value can
            # contain unusual chars in fuzz cases; cheap substring grab
            # is sufficient for the well-formed Slack URLs we see.
            marker = "thread_ts="
            idx = permalink.find(marker)
            if idx >= 0:
                tail = permalink[idx + len(marker):]
                # Stop at next `&` or end of string.
                end = tail.find("&")
                candidate = tail if end < 0 else tail[:end]
                # Cheap validation: must look numeric (slack ts shape).
                try:
                    float(candidate)
                    thread_ts = candidate
                except ValueError:
                    thread_ts = None
        if not thread_ts:
            # Genuine top-level mention — thread parent IS this message.
            thread_ts = ts_str

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
