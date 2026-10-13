# HQ brand for the Agency Kit

These are the brand rules every surface the pack renders follows: the welcome
message, the setup wizard, the practice client, and any page or document a
skill writes for the agency's own team.

## Name

- Product name: **HQ Agency Kit**.
- Short form in prose: "the Agency Kit" or "the kit".
- The platform is always **HQ**. Never rename HQ, and never rename a command.
  `hq`, `/agency-setup`, `/client-onboarding` and every other CLI or slash
  command token stays exactly as written, including inside code spans.

## Palette

Taken from the HQ marketing site (hqforwork.com). Values live in `tokens.css`.

| Token | Value | Use |
|---|---|---|
| `--hq-bg` | `#000000` | Page background (dark only) |
| `--hq-surface` | `rgba(255, 255, 255, 0.03)` | Panels |
| `--hq-text` | `#ffffff` | Headings |
| `--hq-text-secondary` | `rgba(255, 255, 255, 0.70)` | Body copy |
| `--hq-muted` | `rgba(255, 255, 255, 0.50)` | Labels, captions |
| `--hq-line` | `rgba(255, 255, 255, 0.10)` | Hairline rules |
| `--hq-line-strong` | `rgba(255, 255, 255, 0.50)` | Secondary button border |
| `--hq-accent` | `#e56b2e` | Featured tint and badges only, never a button fill |

## Type

Geist for navigation, body, headings and buttons, falling back to Inter and
sans-serif. Fraunces italic for one accent word per headline at most. Buttons
and navigation are 11px uppercase with 0.16em tracking. Corners are square.
No card containers: separate content with hairline rules and opacity steps.

## Voice

Plain, direct, second person. Short sentences. Say what to do and what will
happen. No hype, no metaphors, no closers.

## Where the brand shows up

| Surface | File |
|---|---|
| Install welcome | `package.yaml` (`initialization.welcome`) |
| Setup wizard copy | `skills/agency-setup/SKILL.md` |
| Practice client intro | `skills/practice-client/SKILL.md` |
| Pack README | `README.md` |

The agency's own brand is separate. It lives in the agency playbook under
`companies/{firm}/knowledge/agency-playbook/` and is what client-facing
documents use. HQ branding never appears on anything a client of the agency
sees.
