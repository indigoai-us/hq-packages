---
title: Set up iMessage access for HQ
description: Grant the two macOS permissions hq-imessage needs, then test a read and a send.
---

# Set up iMessage access for HQ

`hq-imessage` reads and sends texts using the Messages account already signed
in on this Mac. It needs two macOS permissions. You grant both once per app
that runs it.

## Before you start

- Open Messages on this Mac and sign in with your Apple ID.
- To send and receive green-bubble SMS too, turn on **Text Message
  Forwarding** on your iPhone: Settings → Apps → Messages → Text Message
  Forwarding → this Mac.

## 1. Full Disk Access (for reading)

Messages keeps its history in a protected database. The app that runs HQ
commands needs Full Disk Access to read it.

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Turn on the app you run HQ from: Terminal, iTerm, Claude, Cursor, or
   whatever hosts your session.
3. For a local bot that runs in the background, also add the program that
   runs it. `hq bot status` shows the bot's process; add that binary (often
   `node` or the `hq` CLI) with the **+** button.
4. Quit and reopen the app so the change applies.

## 2. Automation → Messages (for sending)

Sends go through Messages.app, so macOS asks once whether the app may
control Messages.

1. Run a test send (below). macOS shows "… wants to control Messages". Click
   **Allow**.
2. If you clicked Don't Allow, fix it in **System Settings → Privacy &
   Security → Automation**: find the app and turn on **Messages**.

## 3. Check it

```bash
M=core/packages/hq-pack-imessage/scripts/hq-imessage.sh
bash "$M" doctor
```

Both `database_readable` and `messages_automation` should be `true`.

Then send yourself a test:

```bash
bash "$M" send '<your own phone number>' 'HQ iMessage test'
```

The result should say `"confirmed_in_history": true`.

## 4. Let a bot text people on its own (optional)

Bots running unattended can only text people on your allowlist. You add
them; bots can't.

```bash
bash "$M" allow add '+15551234567'      # a person
bash "$M" chats --query Family          # find a group's chat id
bash "$M" allow add 'any;+;chat123456'  # a group, by chat id
bash "$M" allow list
```

The allowlist lives at `~/.hq/imessage/allow.txt`, one entry per line.

## Troubleshooting

| What you see | Fix |
|---|---|
| "Can't open the Messages database" | Full Disk Access is missing for the app running the command. Add it and restart that app. |
| "Messages refused the send … Automation" | Turn on Messages for that app under Privacy & Security → Automation. |
| `confirmed_in_history: false` | Messages may still be sending. Check with `read <target> 3`. If the person isn't on iMessage, retry with `--service SMS`. |
| Message text shows as `(no text)` | It was a sticker, reaction, or other special item with no plain text. |
| A file send fails | Messages can only attach files it can read. Copy the file into `~/Pictures` or `~/Downloads` first. |

## What it stores

- Nothing from your messages. Reads happen live from the Messages database,
  opened read-only.
- `~/.hq/imessage/cursor-<bot>.json`: the last message id each bot has seen.
- `~/.hq/imessage/allow.txt`: your send allowlist for unattended bots.
