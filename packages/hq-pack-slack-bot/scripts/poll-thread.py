#!/usr/bin/env python3
"""Poll a Slack thread for new human replies and emit Monitor events.

Designed for use as the `command` argument of a slack-mention-worker's
`Monitor(...)` tool call. Replaces the previous inline bash+python recipe
in the worker system prompt — that recipe shipped at least two distinct
silent failure modes (`$()` capture of the parsing pipeline, and
python's default block-buffered stdout swallowing events). Both are
impossible when the polling logic lives in a single pure-python process
with `flush=True`.

Bot-agnostic: reads the xoxb- token from the `BOT_TOKEN` env var. The
worker exports this once at startup (see step 2 of the system prompt).

Required env:
  BOT_TOKEN

Required args:
  --channel <id>          Slack channel id (e.g. C0123456789)
  --thread-ts <ts>        The thread to poll
  --bot <user_id>         Bot user id to filter out from REPLY events

Optional args:
  --cursor-file <path>    Default /tmp/hq-slack-bot.poll.<thread_ts>.cursor
  --seed <ts>             Used only if cursor file does not exist (typical:
                          pass the ts of the worker's ack post)
  --interval <seconds>    Default 75 — Slack rate limits are generous
  --heartbeat-every <N>   Off by default. Set to N>0 to emit a HEARTBEAT
                          stdout line every Nth poll iteration. Use only
                          for active debugging — production should rely on
                          the cursor file's mtime as the liveness signal.

Stdout (one line per Monitor event):
  REPLY ts=<slack_ts> user=<uid> text=<one-line text>
  ERROR <type>:<detail>        (deduped — only emitted on transition)
  RECOVERED                    (after a previously-emitted ERROR clears)
  HEARTBEAT ts=<unix> cursor=…  (only when --heartbeat-every N>0 is passed)

The cursor file is the recovery contract: a relaunch with the same
`--cursor-file` picks up exactly where the prior process left off
without re-emitting old messages. The file is also touched on every
successful poll (even when the cursor value is unchanged), so its
mtime answers "when did this worker last successfully poll?" without
burning a Monitor event. To check:
  stat -c %Y /tmp/hq-slack-bot.poll.<thread_ts>.cursor
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request


SLACK_API = "https://slack.com/api/conversations.replies"
SKIP_SUBTYPES = {"bot_message", "channel_join", "channel_leave",
                 "message_changed", "message_deleted"}


def emit(line: str) -> None:
    print(line, flush=True)


def load_cursor(cursor_file: str, seed: str | None, thread_ts: str) -> float:
    if os.path.exists(cursor_file):
        try:
            return float(open(cursor_file).read().strip())
        except (ValueError, OSError):
            pass
    if seed:
        try:
            return float(seed)
        except ValueError:
            pass
    return float(thread_ts)


def save_cursor(cursor_file: str, cursor: float) -> None:
    """Atomically write cursor to file. Called per-poll so mtime tracks
    last-successful-poll time, even when cursor value is unchanged."""
    tmp = cursor_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(cursor))
    os.replace(tmp, cursor_file)


def poll_once(token: str, channel: str, thread_ts: str, bot: str,
              cursor: float, decoder: json.JSONDecoder) -> tuple[float, str | None]:
    url = f"{SLACK_API}?channel={channel}&ts={thread_ts}&oldest={cursor}&limit=50"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = decoder.decode(resp.read().decode("utf-8", errors="replace"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
        return cursor, f"net:{type(e).__name__}:{e}"
    except (json.JSONDecodeError, ValueError) as e:
        return cursor, f"parse:{type(e).__name__}:{e}"

    if not data.get("ok"):
        return cursor, f"api:{data.get('error', 'unknown')}"

    max_ts = cursor
    for m in data.get("messages", []):
        ts_str = m.get("ts") or ""
        try:
            ts_num = float(ts_str)
        except ValueError:
            continue
        if ts_num > max_ts:
            max_ts = ts_num
        if ts_num <= cursor:
            continue
        user = m.get("user") or m.get("bot_id") or ""
        if user == bot:
            continue
        if (m.get("subtype") or "") in SKIP_SUBTYPES:
            continue
        text = (m.get("text") or "").replace("\n", " ").replace("\r", " ")
        emit(f"REPLY ts={ts_str} user={user} text={text}")

    return max_ts, None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--channel", required=True)
    p.add_argument("--thread-ts", required=True)
    p.add_argument("--bot", required=True)
    p.add_argument("--cursor-file", default=None)
    p.add_argument("--seed", default=None)
    p.add_argument("--interval", type=int, default=75)
    p.add_argument("--heartbeat-every", type=int, default=0,
                   help="Off by default. Set N>0 to emit HEARTBEAT lines for "
                        "active debugging. Production should rely on cursor file mtime.")
    args = p.parse_args()

    token = os.environ.get("BOT_TOKEN", "").strip()
    if not token:
        emit("ERROR config:BOT_TOKEN not set in env (worker must export it before launching this script)")
        return 2

    cursor_file = args.cursor_file or f"/tmp/hq-slack-bot.poll.{args.thread_ts}.cursor"
    cursor = load_cursor(cursor_file, args.seed, args.thread_ts)
    save_cursor(cursor_file, cursor)

    def _graceful_exit(*_):
        sys.exit(0)

    signal.signal(signal.SIGTERM, _graceful_exit)
    signal.signal(signal.SIGINT, _graceful_exit)

    decoder = json.JSONDecoder(strict=False)
    hb_counter = 0
    prev_err: str | None = None

    while True:
        new_cursor, err = poll_once(token, args.channel, args.thread_ts,
                                    args.bot, cursor, decoder)
        if err is not None:
            if err != prev_err:
                emit(f"ERROR {err}")
                prev_err = err
        else:
            if prev_err is not None:
                emit("RECOVERED")
                prev_err = None
            if new_cursor > cursor:
                cursor = new_cursor
            # Touch on every successful poll, even when cursor is unchanged:
            # the file's mtime is the liveness signal.
            save_cursor(cursor_file, cursor)

        if args.heartbeat_every > 0:
            hb_counter += 1
            if hb_counter >= args.heartbeat_every:
                emit(f"HEARTBEAT ts={int(time.time())} cursor={cursor}")
                hb_counter = 0

        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
