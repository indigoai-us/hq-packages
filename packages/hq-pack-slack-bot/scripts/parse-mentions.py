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
    M\\t<ts>\\t<user>\\t<thread_ts>\\t<text>   ← one per @-mention (ascending ts)

When `--emit-threads` is also passed, the watcher additionally needs to
discover threads with replies so it can poll them for in-thread
@-mentions. In that mode the parser emits a second row type:

    T\\t<thread_ts>\\t<reply_count>\\t<latest_reply>   ← one per top-level
                                  message whose reply_count > 0 (regardless
                                  of whether the parent itself mentioned
                                  the bot — that case is also emitted as
                                  an M row).

The row prefix lets the watcher cheaply distinguish the two streams
without a second parser pass.
"""

import argparse
import json
import sys


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--last-ts", required=True, help="per-channel cursor, numeric")
    p.add_argument("--bot", required=True, help="bot user id whose @-mention we filter for")
    p.add_argument("--emit-threads", action="store_true",
                   help="also emit T\\t rows for top-level messages with reply_count > 0; "
                        "the watcher uses these to schedule per-thread polling so it can "
                        "catch @-mentions that land in thread REPLIES, not just parents.")
    p.add_argument("--all-messages", action="store_true",
                   help="firehose mode: treat EVERY non-bot, non-subtype message as a match, "
                        "not just ones containing the bot's @-mention token. Used for "
                        "dedicated channels (e.g. #hq-feedback) where the bot should triage "
                        "every message without being tagged.")
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

    mention_rows = []
    # Thread-head rows are keyed on parent ts (the canonical thread_ts)
    # so duplicates from `messages` re-listing the parent collapse.
    thread_rows: dict[str, tuple[str, int, str]] = {}
    max_ts: float | None = None
    for m in messages:
        ts_str = m.get("ts") or ""
        try:
            ts_num = float(ts_str)
        except ValueError:
            continue
        if max_ts is None or ts_num > max_ts:
            max_ts = ts_num

        subtype = m.get("subtype") or ""

        # Thread-head discovery (only applies to top-level messages we
        # haven't already seen — `last` cursor bound — and only when
        # the caller asked for it). Parent messages carry reply_count
        # and latest_reply; replies do not.
        if args.emit_threads and ts_num > last and subtype not in skip_subtypes:
            reply_count = m.get("reply_count") or 0
            if reply_count and reply_count > 0:
                # For a parent, thread_ts in the API response equals its
                # own ts. We key on ts to be safe even if the field is
                # absent.
                thread_ts_key = m.get("thread_ts") or ts_str
                thread_rows[thread_ts_key] = (
                    thread_ts_key,
                    int(reply_count),
                    str(m.get("latest_reply") or ts_str),
                )

        if ts_num <= last:
            continue

        # Skip the bot's own posts (replies-to-itself in a thread it
        # owns would otherwise re-fire the watcher).
        author = m.get("user") or m.get("bot_id") or ""
        if author == args.bot:
            continue

        if subtype in skip_subtypes:
            continue

        text = m.get("text") or ""
        # Firehose channels match every message; normal channels require
        # the literal @-mention token in the body.
        if not args.all_messages and mention_token not in text:
            continue

        thread_ts = m.get("thread_ts") or m.get("ts")
        clean_text = text.replace("\n", " ").replace("\r", " ")
        mention_rows.append((ts_num, ts_str, author, thread_ts, clean_text))

    mention_rows.sort(key=lambda r: r[0])

    print(f"OK={'true' if ok else 'false'}")
    print(f"ERR={err}")
    print(f"MAX_TS={max_ts if max_ts is not None else ''}")
    print("")
    for _, ts_str, user, thread_ts, text in mention_rows:
        print(f"M\t{ts_str}\t{user}\t{thread_ts}\t{text}")
    if args.emit_threads:
        for thread_ts_key, reply_count, latest_reply in thread_rows.values():
            print(f"T\t{thread_ts_key}\t{reply_count}\t{latest_reply}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
