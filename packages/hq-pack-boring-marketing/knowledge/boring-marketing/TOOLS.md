# Tools guide: what each optional tool unlocks

Everything works with zero keys. Every skill completes its job with your agent's own web search and fetch plus files you provide (exports, call logs, CSVs, screenshots). Tools make research deeper and let skills act (push a sequence, generate an image, read your ad account). Put keys in `.env` at the workspace root, or in `./brands/<client>/.env` for one client. Values are never shown by any skill.

## What we use

Every skill works without these. When you want more, this is the stack we run, one pick per job. Skills name the pick at the step where it helps, with the cost and the free way to do it.

| Job | What we use | Cost | Key | Used by |
|---|---|---|---|---|
| Web search for agents | Exa | Free tier, then pay as you go | `EXA_API_KEY` | research skills, `ai-search`, `competitive-intel` |
| Read, crawl and extract pages | Firecrawl | Free tier, then plans | `FIRECRAWL_API_KEY` | research skills, `first-screen-check`, `site-audit` |
| Search volumes, SERPs, keyword data | DataForSEO | Pay as you go | `DATAFORSEO_LOGIN`, `DATAFORSEO_PASSWORD` | `keyword-research`, `local-seo-plan`, `programmatic-seo` |
| Images and GIFs | GPT Image 2.6 (OpenAI) | Pay per image | `OPENAI_API_KEY` or `REPLICATE_API_TOKEN` | `creative` |
| Video | Seedance 2.5 (ByteDance) via Higgsfield or Replicate | Pay per clip | `HF_API_KEY_ID` + `HF_API_KEY_SECRET`, or `REPLICATE_API_TOKEN` | `creative` |
| Presenter and UGC-style ad video, fast static ad formats | Higgsfield Marketing Studio (CLI: `npm i -g @higgsfield/cli`, then `higgsfield auth login`) | Plans with credits | Higgsfield login | `creative` |
| Voice and voiceover | ElevenLabs | Free tier, then plans | `ELEVENLABS_API_KEY` | `creative` |
| Meta ads | Meta's official Ads MCP server and Ads CLI, or the Marketing API | Free with an ad account | `META_ACCESS_TOKEN` | `meta-ads`, `paid-ads` |
| Google Ads | Google Ads API | Free | `GOOGLE_ADS_*` (see Ads below) | `google-ads-tracking`, `paid-ads` |
| Social posting and scheduling | Zernio (API and MCP, about 18 platforms) | Plans | `ZERNIO_API_KEY` | `social-content`, `content-atomizer`, `google-business-profile` |
| Many data APIs behind one key | treg | Pay per call | `TREG_TOKEN` | any skill that wants SERP, social, lead or ad data without separate accounts |
| Search Console, Business Profile | Google | Free | service account / your login | `local-seo-plan`, `google-business-profile`, `performance-review` |
| Finding local businesses to pitch | boringfunnels (made by the author of this library) | Free search, paid Pro | none, it runs as an MCP | `find-local-clients`, `pitch-the-fix`, `first-screen-check` |

Free first: when a skill names a paid tool, it gives the free way before it, and says what the tool adds. The author's own tool is marked wherever a skill mentions it, never replaces the free path, and no skill needs it.

**Partners.** Some tools may sponsor a mention. A partner is always a tool we already use or would name anyway, it's marked ◆ wherever it appears, and it never replaces the free path or a better pick. There are no partners yet.

One section per toolset below, in the order the skills check them. Each says what the tool unlocks, what happens without it, which skills use it, a rough cost, and where to get it. Prices and platform lists were checked on 2026-09-02 unless a section says otherwise; the pages we checked are listed at the end.

To see what is live right now, say "what should I add" to `/start-here` (or run `python3 <your skills folder>/start-here/scripts/capability.py --markdown`). You get one sentence naming the single most useful missing key for your current goal, once, and then the skill carries on at baseline.

## Web scraping (`web-scrape`): Firecrawl (`FIRECRAWL_API_KEY`)
- Unlocks: full-page, JS-rendered reads for every research skill (onboarding, audits, competitor teardowns, keyword SERP checks).
- Without it: Claude Code's WebFetch reads pages as summaries; results are labelled accordingly.
- Used by: /start-here, /brand-voice, /positioning-angles, /audience-research, /competitive-intel, /keyword-research, /seo-content, /ai-search, /landing-page, /programmatic-seo, /google-business-profile, /local-seo-plan, /service-area-pages, /reviews, /first-screen-check, /find-local-clients, /pitch-the-fix, /long-form-article, /site-audit
- Cost: free tier of 1,000 credits a month with no card; Hobby from $16 a month (billed yearly) for 5,000 credits; top-ups in $5 batches. A full onboarding is a few hundred page reads. [1]
- Get it: firecrawl.dev → sign up → https://www.firecrawl.dev/app/api-keys

## Web search (`web-search`): built in
- Unlocks: live search-result checks (what ranks today, People Also Ask, autocomplete, recent platform changes).
- Without it: nothing to add in Claude Code, Codex or Cursor, which all search the web. An agent without web search falls back to model knowledge and says so.
- Used by: /keyword-research, /seo-content, /competitive-intel, /ai-search, /positioning-angles, /lead-magnet, /google-business-profile, /local-seo-plan, /reviews, /find-local-clients, /long-form-article
- Cost: none. Included with your agent.
- Get it: nothing to do.

## Social data (`social-data`): ScrapeCreators (`SCRAPECREATORS_API_KEY`)
- Unlocks: real posts, comments, profiles, transcripts and ad-library entries for audience research, competitor recon and social canon extraction, instead of whatever a public page shows a logged-out reader.
- Without it: WebFetch reads the public pages it can reach; samples are smaller and labelled as such.
- Used by: /audience-research, /competitive-intel, /social-content, /content-atomizer
- Platforms verified 2026-09-02 at https://docs.scrapecreators.com: Reddit (subreddits, posts, comments, search), X (profiles, posts, transcripts, communities), Instagram (profile, posts, reels, transcripts, search, comments), TikTok (profile, videos, transcripts, search, trending, comments, followers), YouTube (channel, videos, transcripts, search, playlists, shorts), LinkedIn (profiles, companies, posts), Threads (profiles, posts, search), Facebook (profile, posts, reels, groups), Bluesky, Pinterest, Telegram, and the Facebook, TikTok, Google and LinkedIn ad libraries. The skills only call endpoints that appear in those docs.
- Cost: pay-as-you-go credits that never expire; 100 free credits with no card; from $47 for 25,000 credits (about $1.88 per 1,000 requests). One request is one credit on most endpoints; cached results are free. [2]
- Get it: scrapecreators.com → sign up → the key is on your dashboard.

## Creative (`creative`): Replicate (`REPLICATE_API_TOKEN`)
- Unlocks: image and video generation plus the vision-QA loop that scores every output against your brand kit before you see it.
- Without it: /creative writes model-ready prompts you can paste into any image or video tool; nothing is generated for you.
- Used by: /creative, /paid-ads, /landing-page, /meta-ads
- Cost: pay per use, priced per model, either per output or per second of video (about $0.07 for a default image at 1K and $0.18 to $0.40 per second for production video on 2026-11-13; the creative skill's model registry carries every price). Some models are free to try, then you add billing. [3]
- Get it: https://replicate.com/account/api-tokens

## Email platform (`esp`): Kit, beehiiv, and detection for others
- Unlocks: sequences and newsletter editions push straight to your list as drafts (Kit: `KIT_API_KEY`; beehiiv: `BEEHIIV_API_KEY` + `BEEHIIV_PUBLICATION_ID`), and /newsletter reads your own click data. Loops, Resend, Mailchimp and HubSpot keys (`LOOPS_API_KEY`, `RESEND_API_KEY`, `MAILCHIMP_API_KEY`, `HUBSPOT_ACCESS_TOKEN`) are detected so the skills format for your platform and hand you files to import.
- Without it: every email is written to `./campaigns/<name>/emails/` as files with subject-line variants and timing; you paste them in.
- Used by: /email-sequences, /newsletter, /lead-magnet
- Cost: Kit is free up to 10,000 subscribers, paid from $33 a month; its pricing page lists API access under paid plans, but Kit's help centre says V4 keys are not restricted by plan, so try the free plan first. beehiiv's free Launch plan (up to 2,500 subscribers) includes API access; Scale is from $43 a month. [4][5]
- Get it: Kit → Settings → Developer → V4 Keys (https://app.kit.com/account_settings/developer_settings). beehiiv → Settings → Workspace → API (https://app.beehiiv.com/settings/workspace/api; needs the Owner or Admin role and a verified account). Your Publication ID is on the same page.

Nothing is ever sent on your behalf: a push creates drafts, and the skill asks first.

## Analytics (`analytics`): GA4 service account or PostHog, read-only
- Unlocks: /performance-review pulls your real traffic and conversion numbers instead of waiting for a pasted export, and writes what it learns to `./brand/learnings.md` for every other skill to use.
- Without it: paste a CSV export or a dashboard screenshot; the review runs on that.
- Used by: /performance-review, /keyword-research, /ads-incrementality-check
- Cost: GA4's API is free with your Google account. PostHog is free up to 1 million events a month and pay-as-you-go after; usage stops at the free limit unless you add a card, so there are no surprise bills. [6]
- Get it: GA4 → create a service account in Google Cloud, download its JSON key, set `GOOGLE_APPLICATION_CREDENTIALS` to the file path, and add the service-account email as a Viewer on your GA4 property (set `GA4_PROPERTY_ID`). PostHog → https://us.posthog.com/settings/user-api-keys → `POSTHOG_API_KEY` (+ `POSTHOG_PROJECT_ID`).

## Search Console (`search-console`): Google service account
- Unlocks: your real queries, impressions and click-through rates feed keyword research, content refreshes and the monthly review.
- Without it: keyword work uses live search checks and model-knowledge estimates, labelled as such.
- Used by: /performance-review, /seo-content, /keyword-research, /local-seo-plan, /service-area-pages, /site-audit
- Cost: free with your Google account.
- Get it: the same service account as GA4 (`GOOGLE_APPLICATION_CREDENTIALS`); add its email as a user on your Search Console property and set `GSC_SITE_URL`.

## Core Web Vitals: Google PageSpeed Insights (`PAGESPEED_API_KEY`, optional `CRUX_API_KEY`)
- Unlocks: /site-audit measures phone speed on the homepage and key templates, with real-visitor data where Google has it.
- Without it: the keyless PageSpeed quota is shared and often used up, so the audit reports Core Web Vitals as not checked.
- Used by: /site-audit
- Cost: free. Checked 2026-11-16.
- Get it: Google Cloud console → enable the PageSpeed Insights API (and the Chrome UX Report API for real-visitor data) → Credentials → create an API key.

## Ads (`ads`): Meta (`META_ACCESS_TOKEN`) and Google Ads (`GOOGLE_ADS_DEVELOPER_TOKEN`)
- Unlocks: /paid-ads reads real campaign, ad-set and creative performance for kill/scale/iterate decisions; /google-ads-tracking reads the conversion setup; /meta-ads creates campaigns (paused) and checks the pixel and Conversions API; /ads-incrementality-check pulls spend and conversions for the pause test; /performance-review includes spend in the diagnosis.
- Without it: you paste an export or screenshots from Ads Manager or the Google Ads UI, and a call log or CSV from your phone system; the ad matrix, tracking audit, pause test and policy checks still run.
- Used by: /paid-ads, /google-ads-tracking, /ads-incrementality-check, /meta-ads, /performance-review
- Cost: both APIs are free; you pay only for the ads. Google Ads needs a developer token from a Manager account (basic access is granted after a short review); Meta needs an app with the Marketing API and a token from your ad account.
- Get it: Meta → developers.facebook.com → create an app → Marketing API → generate an access token. Google Ads → Manager account → Tools → API Center → developer token. Reads also need OAuth credentials and the account IDs: `GOOGLE_ADS_CLIENT_ID`, `GOOGLE_ADS_CLIENT_SECRET`, `GOOGLE_ADS_REFRESH_TOKEN`, `GOOGLE_ADS_LOGIN_CUSTOMER_ID` (the Manager account) and `GOOGLE_ADS_CUSTOMER_ID` (the ad account), all from Google Cloud and Google Ads.

Nothing here spends money: the skills read; you approve changes in the ad platform yourself.

## Social API (`social-api`): X (`X_BEARER_TOKEN`)
- Unlocks: /social-content scores your own past posts, so the pattern library learns what your audience actually engages with.
- Without it: the skill works from your pasted top posts or the public profile it can fetch.
- Used by: /social-content, /performance-review
- Cost: X's API is pay per use with no free tier: $0.005 per post read and $0.015 per post created ($0.20 if the post contains a link); credits are bought up front. For most solo accounts that is a few dollars a month. [7]
- Get it: https://console.x.com → create a project and app → bearer token.

## Scheduling (`scheduling`): Zernio (`ZERNIO_API_KEY`), Buffer (`BUFFER_ACCESS_TOKEN`) or Hootsuite (`HOOTSUITE_API_KEY`)
- Unlocks: atomized posts and social drafts go into your scheduling queue directly instead of being copy-pasted.
- Without it: every post is written to a per-platform file in `./campaigns/`; you paste into your scheduler.
- Used by: /content-atomizer, /social-content
- Cost: Buffer's free plan covers 3 channels with 10 scheduled posts per channel and includes an API key (3,000 requests a month); Essentials is from $5 a month per channel. Hootsuite Standard is from $99 a month billed annually, with a 14-day trial. [8][9]
- What we use: Zernio, one API and MCP for about 18 platforms (zernio.com). Buffer is the free option for a few channels.
- Get it: Buffer → https://publish.buffer.com/settings/api. Hootsuite → hootsuite.com → developer portal → create an app.

Scheduling is the only action here that touches a live account. The skill always shows you the posts and asks before it queues anything.

## One connection for many apps: Composio (`COMPOSIO_API_KEY`)
- Unlocks: one account that holds the sign-ins for many apps at once. Composio manages the OAuth and exposes the apps to Claude Code as an MCP server, so you connect once instead of collecting a key per platform. Verified 2026-09-02 in its toolkit directory (1,000+ apps; 1,452 toolkits listed that day): Kit, beehiiv, Mailchimp and HubSpot (email platform); Google Analytics and PostHog (analytics); Google Search Console (search-console); Meta Ads and Google Ads (ads); Buffer (scheduling); X (social-api; Composio stopped supplying its own X credentials in February 2026, so you bring your own X developer app and X's pay-per-use pricing still applies). Not seen: Hootsuite.
- Without it: nothing changes; every toolset above works with its own native key or at baseline.
- Used by: any skill in the sections above whose toolset has no native key set: /email-sequences, /newsletter, /performance-review, /keyword-research, /seo-content, /paid-ads, /social-content, /content-atomizer.
- Cost: free tier of 100,000 tool calls a month with unlimited connected accounts and no card; Pro from $29 a month; hard caps so there are no surprise bills. The apps behind it keep their own pricing. [10]
- Get it: simplest route is `claude mcp add --transport http composio https://connect.composio.dev/mcp`, then finish the sign-in it opens; no key is needed for that route (the command form is from Composio's Claude Code page and the URL from its Claude setup page). For the key-based route, create `COMPOSIO_API_KEY` at https://dashboard.composio.dev and put it in `.env`.
- How it fits: if you'd rather not manage five keys, connect Composio once; the skills treat it as the provider for any toolset above that has no native key. Native keys win when both exist.

## Google Business Profile: your own account, free
- Unlocks: /google-business-profile and /reviews work from the real profile (categories, services, photos, posts, every review and reply) instead of what a logged-out search shows.
- Without it: the skills read the public listing through search results and the review sites that open without a login, and say which facts they could not see.
- Used by: /google-business-profile, /reviews, /local-seo-plan, /performance-review
- Cost: free. No key in `.env`: you (or the client) export or paste from the profile dashboard, or share Performance screenshots.
- Get it: business.google.com, signed in as an owner or manager of the profile.

## Call logs and lead exports: files you already have, free
- Unlocks: /speed-to-lead counts missed calls and reply times, and /ads-incrementality-check uses the phone log as the denominator for the pause test.
- Without it: the skills ask for a week of numbers by hand and label the result as a small sample.
- Used by: /speed-to-lead, /ads-incrementality-check, /performance-review
- Cost: free. Any phone system or CRM that exports a CSV (date, time, caller, answered or missed, duration).

## Search volumes: DataForSEO (optional, paid)
- Unlocks: real monthly search volumes for /keyword-research and /local-seo-plan, instead of autocomplete and live search checks.
- Without it: the free path (Google autocomplete, live results, People Also Ask, and Search Console if connected) ranks topics without volumes, and any volume is labelled as an estimate to verify before you spend on it.
- Used by: /keyword-research, /local-seo-plan
- Cost (checked 2026-11-13): pay as you go with no subscription; $50 minimum top-up that does not expire, plus a $1 trial credit on sign-up. [11]
- Get it: app.dataforseo.com → register → API login and password in the dashboard.

## Finding and pitching local businesses: boringfunnels (made by the author of this library)
- Unlocks: boringfunnels (made by the author of this library, paid Pro with a free search) can do part of this for you: its web search finds local businesses losing customers, and its prospect tool reads a named business's Google rating, reviews and ads.
- Without it: /find-local-clients, /first-screen-check and /pitch-the-fix do the same work by hand from free data (the rating, review count, site and owner replies anyone can see). The free path gets the same answer.
- Used by: /find-local-clients, /pitch-the-fix, /first-screen-check
- Cost: free search, paid Pro.
- Get it: boringfunnels.com (made by the author of this library).

## Our picks with no section above

- **Exa** (`EXA_API_KEY`): semantic web search built for agents. Finds pages a keyword search misses, and returns clean text. Get it at exa.ai.
- **GPT Image 2.6** (`OPENAI_API_KEY`): OpenAI's image model (Flare for fast drafts, Sunburst for finals, GIFs up to 16 frames), called directly or through Replicate. Get it at platform.openai.com.
- **Higgsfield** (`HF_API_KEY_ID`, `HF_API_KEY_SECRET`): one API for 50+ image and video models, including Seedance. Pay as you go. Get it at higgsfield.ai.
- **ElevenLabs** (`ELEVENLABS_API_KEY`): voiceover and voice cloning for video ads and talking heads. Get it at elevenlabs.io.
- **Meta's official Ads MCP server and Ads CLI**: lets an agent read and manage ads through Meta's own connector. Turn it on in Meta Business Suite, Settings, Integrations, Ads MCP server. Get it at developers.facebook.com (Ads AI Connectors).
- **Zernio** (`ZERNIO_API_KEY`): one API and MCP to post and schedule across about 18 platforms, including Google Business Profile, Facebook, Instagram, LinkedIn and X. Get it at zernio.com.
- **treg** (`TREG_TOKEN`): a pay-per-call gateway to thousands of data endpoints (SEO, social, leads, ads, scraping) behind one token and one MCP. Handy when you'd rather not open five accounts. Get it at treg.to.

## Not included on purpose
AI-visibility measurement services (which AI assistants cite you, and how often) are left out of this pack: they are subscriptions that belong with hosted services, not in skills you run locally. /ai-search checks the answers live instead and labels any share-of-voice figure as a model-knowledge estimate. Rank trackers are left out for the same reason; a search-volume API is the one paid search-data tool a skill may name, as an option after the free path.

## Where the prices came from (checked 2026-09-02 unless noted)
1. Firecrawl: https://www.firecrawl.dev/pricing
2. ScrapeCreators: https://scrapecreators.com/ (pricing section on the home page); docs at https://docs.scrapecreators.com
3. Replicate: https://replicate.com/pricing and https://replicate.com/docs/topics/billing
4. Kit: https://kit.com/pricing and https://help.kit.com/en/articles/9902901-kit-api-overview
5. beehiiv: https://www.beehiiv.com/pricing and https://www.beehiiv.com/support/article/13091918395799-how-to-access-your-publication-id-or-api-keys
6. PostHog: https://posthog.com/pricing
7. X API: https://docs.x.com/x-api/getting-started/pricing
8. Buffer: https://buffer.com/pricing and https://developers.buffer.com/
9. Hootsuite: https://www.hootsuite.com/plans
10. Composio: https://composio.dev/pricing; toolkit directory https://composio.dev/toolkits; Claude Code setup https://composio.dev/toolkits/composio/framework/claude-code and https://composio.dev/claude

11. DataForSEO (checked 2026-11-13): https://dataforseo.com/pricing

Prices change. If a number here looks off, the vendor page wins.
