#!/usr/bin/env python3
"""Filter a Slack conversations.history response down to @-mentions of a
specific bot, emitting watcher events on stdout.

Replaces a jq pipeline because Slack message bodies occasionally carry
literal control chars (U+0000–U+001F in block_id values and pasted-log
text content). The stdlib json module with strict=False tolerates those;
jq does not.

Usage (pipe the conversations.history JSON in on stdin):

    curl ... https://slack.com/api/conversations.history?channel=<C>... \\
      | parse-mentions.py --last-ts "$LAST_TS" --bot "$BOT_USER_ID"

Output (lines, in order):

    OK=<true|false>            ← status header
    ERR=<error-string-or-empty>
    MAX_TS=<numeric-or-empty>  ← high-water-mark across ALL messages seen
                                  (not just mentions — so the cursor doesn't
                                   re-fetch the same channel-noise next tick)
    <blank line separator>
    <ts>\\t<user>\\t<thread_ts>\\t<text>   ← one per @-mention (ascending ts)

The watcher loop reads stdout, splits the prefix block from the rows,
and fires one SPAWN per row whose ts isn't already in the sentinel dir.
"""

import argparse
import json
import sys


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--last-ts", required=True, help="per-channel cursor, numeric")
    p.add_argument("--bot", required=True, help="bot user id whose @-mention we filter for")
    args = p.parse_args()

    # strict=False mirrors monitor-liveops/parse-history.py — see the
    # docstring there for rationale. Without it, real Slack payloads with
    # paste content silently fail and the watcher gets stuck.
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
    messages = data.get("messages") or []

    try:
        last = float(args.last_ts)
    except (ValueError, TypeError):
        last = 0.0

    # The literal Slack-encoded form of an @-mention in message text.
    mention_token = f"<@{args.bot}>"

    skip_subtypes = {
        "channel_join",
        "channel_leave",
        "bot_message",
        "message_changed",
        "message_deleted",
    }

    new_rows = []
    max_ts: float | None = None
    for m in messages:
        ts_str = m.get("ts") or ""
        try:
            ts_num = float(ts_str)
        except ValueError:
            continue
        if max_ts is None or ts_num > max_ts:
            max_ts = ts_num
        if ts_num <= last:
            continue

        # Skip the bot's own posts (replies-to-itself in a thread it
        # owns would otherwise re-fire the watcher).
        author = m.get("user") or m.get("bot_id") or ""
        if author == args.bot:
            continue

        subtype = m.get("subtype") or ""
        if subtype in skip_subtypes:
            continue

        text = m.get("text") or ""
        if mention_token not in text:
            continue

        thread_ts = m.get("thread_ts") or m.get("ts")
        clean_text = text.replace("\n", " ").replace("\r", " ")
        new_rows.append((ts_num, ts_str, author, thread_ts, clean_text))

    new_rows.sort(key=lambda r: r[0])

    print(f"OK={'true' if ok else 'false'}")
    print(f"ERR={err}")
    print(f"MAX_TS={max_ts if max_ts is not None else ''}")
    print("")
    for _, ts_str, user, thread_ts, text in new_rows:
        print(f"{ts_str}\t{user}\t{thread_ts}\t{text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
