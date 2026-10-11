# AI Builders brand for the Agency Kit

The kit is the AI Builders cohort's version of the HQ agency setup. These are
the brand rules every surface the pack renders follows: the welcome message,
the setup wizard, the practice client, and any page or document a skill writes
for a student.

## Name

- Product name: **AI Builders Agency Kit**.
- Short form in prose: "the Agency Kit" or "the kit".
- The platform is always **HQ**. Never rename HQ, and never rename a command.
  `hq`, `/agency-setup`, `/client-onboarding` and every other CLI or slash
  command token stays exactly as written, including inside code spans.

## Palette

Taken from joinaibuilders.com. Values live in `tokens.css`.

| Token | Value | Use |
|---|---|---|
| `--aib-bg` | `#090909` | Page background |
| `--aib-surface` | `rgba(255, 255, 255, 0.03)` | Panels and cards |
| `--aib-text` | `#ffffff` | Body text |
| `--aib-text-secondary` | `rgba(255, 255, 255, 0.72)` | Secondary text |
| `--aib-accent` | `#ffb58e` | Calls to action, highlights |
| `--aib-accent-2` | `#ad9cda` | Secondary highlights |
| `--aib-muted` | `#a4a4a4` | Labels, captions |
| `--aib-line` | `#303030` | Rules and borders |

## Type

Inter, falling back to Arial and sans-serif. Headings are regular weight with
tight leading. Corners are square (2px radius). No drop shadows on text.

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

The agency's own brand (the student's agency) is separate. It lives in the
agency playbook under `companies/{firm}/knowledge/agency-playbook/` and is what
client-facing documents use. AI Builders branding never appears on anything a
client of the agency sees.
