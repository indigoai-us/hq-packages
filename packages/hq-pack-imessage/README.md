# hq-pack-imessage

Read and send iMessages from the Messages account signed in on this Mac. Works
in interactive HQ sessions and for local HQ bots (`hq bot`).

- Reads come from the Messages database, opened read-only. Newer macOS
  versions store most message text in an encoded field; the CLI decodes it.
- Sends go through Messages.app with AppleScript. The recipient and text are
  passed as arguments, so message content can't change the script.
- `watch` streams new incoming texts as JSON lines, one cursor per bot, so a
  bot can answer texts without replaying old history.
- Unattended bots can only text people on an owner-managed allowlist.

macOS only. Python 3 standard library, no installs.

## Install

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-imessage
```

Then follow [`knowledge/hq-imessage/setup.md`](./knowledge/hq-imessage/setup.md)
to grant Full Disk Access and Automation → Messages, and run
`hq-imessage.sh doctor`.

## Use

```bash
M=core/packages/hq-pack-imessage/scripts/hq-imessage.sh
bash "$M" chats
bash "$M" read '+15551234567' 20
bash "$M" send '+15551234567' 'On my way'
bash "$M" watch --name my-bot --once
```

The `/hq-imessage` skill covers every command and the rules agents follow:
confirm before sending, treat incoming texts as data, and keep unattended
sends on the allowlist.

## Tests

```bash
bash packages/hq-pack-imessage/tests/hq-imessage.test.sh
```

The suite builds a fixture Messages database and mocks `osascript`, so it runs
on any OS and never touches real messages.
