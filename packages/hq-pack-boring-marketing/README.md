# hq-pack-boring-marketing

32 marketing skills from [Boring Marketing Skills](https://github.com/boringmarketer/boring-marketing-skills)
by James Dickerson ([@boringmarketer](https://x.com/boringmarketer)), ported to HQ.

- Upstream: `boringmarketer/boring-marketing-skills` v4.1.1, commit
  `7c6678c857fe514f79396ea607aa2a56ea82e676`
- License: MIT, Copyright (c) 2026 Boring Marketing, LLC. See [`LICENSE`](./LICENSE).

Start with `/start-here` and name the business. It writes the brand files the other skills
read and tells you which skill to run next.

## Install

```bash
hq install github:indigoai-us/hq-packages#packages/hq-pack-boring-marketing
```

## Skills

| Stage | Skills |
|---|---|
| Start here | `start-here`, `brand-voice`, `positioning-angles`, `audience-research`, `competitive-intel` |
| Get found | `google-business-profile`, `local-seo-plan`, `service-area-pages`, `ai-search`, `site-audit`, `keyword-research`, `seo-content`, `programmatic-seo` |
| Get chosen | `reviews`, `first-screen-check`, `landing-page`, `direct-response-copy`, `lead-magnet` |
| Get the call | `paid-ads`, `google-ads-tracking`, `ads-incrementality-check`, `meta-ads`, `speed-to-lead`, `creative` |
| Bring them back | `email-sequences`, `newsletter`, `performance-review` |
| Win clients | `find-local-clients`, `pitch-the-fix` |
| Market yourself | `social-content`, `long-form-article`, `content-atomizer` |

## What the port changed

Each `SKILL.md` gets a short "Running in HQ" note after its frontmatter: brand and
campaign files live in the active company's `data/marketing/` folder, API keys come
from HQ secrets, and anything outbound waits for the user's OK. The skill text,
references and scripts are otherwise upstream and unchanged. Details, and the list of
upstream files left out, are in
[`knowledge/boring-marketing/HQ-NOTES.md`](./knowledge/boring-marketing/HQ-NOTES.md).
The upstream README is at
[`knowledge/boring-marketing/README.md`](./knowledge/boring-marketing/README.md).
