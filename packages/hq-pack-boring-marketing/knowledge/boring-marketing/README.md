# Boring Marketing Skills

Free marketing skills for your AI agent: research, positioning, copy, pages, SEO, AI search, ads, email and content, plus a deep pack for local businesses and the people who market them.

32 skills for Claude Code, Codex, Cursor and other agents. They were built from real campaigns, and every one works without a paid tool. MIT licensed.

Made by James Dickerson ([@boringmarketer](https://x.com/boringmarketer)). More at [boringmarketing.com](https://boringmarketing.com). Need clients to use this on? [boringfunnels.com](https://boringfunnels.com) finds local businesses losing customers (I make it). Want agents built for your team? [Work with us](https://boringmarketing.com/#work).

## Install

Any agent (Claude Code, Codex, Cursor and others):

```bash
npx skills add boringmarketer/boring-marketing-skills
```

Claude Code plugin:

```
/plugin marketplace add boringmarketer/boring-marketing-skills
/plugin install boring-marketing@boring-marketing-skills
```

Then type `/start-here` and name the business. It reads the site and the reviews, writes the brand files every other skill uses, and tells you which skill to run next. The first run takes about 3 minutes.

## The skills

Grouped by stage, in the order a customer meets a business.

### Start here

| Skill | What it does |
|---|---|
| `start-here` | Reads the business (yours or a client's), writes the brand files, and routes you to the next skill |
| `brand-voice` | Pulls the voice from the site and reviews so every page and post sounds like the business |
| `positioning-angles` | Finds the angle and the offer that make them the obvious call |
| `audience-research` | Reads reviews, forums and competitors for the words customers actually use |
| `competitive-intel` | Sizes up the rivals that show up first, including what their customers complain about |

### Get found

| Skill | What it does |
|---|---|
| `google-business-profile` | Checks the Google profile against the top 3 in the map pack and writes a month of posts |
| `local-seo-plan` | Decides which services and towns get a page, which get a section, and which to skip |
| `service-area-pages` | Writes town and service pages that aren't the same page with the city swapped |
| `ai-search` | Checks whether ChatGPT, Perplexity and Google's AI name the business, and what to fix if they don't |
| `site-audit` | Crawls the site like Google and the AI crawlers do and ranks the few technical fixes that stop it being found |
| `keyword-research` | Maps what people search, from free autocomplete data, as topics instead of a 5,000-row list |
| `seo-content` | Writes the articles and guides that answer those searches |
| `programmatic-seo` | Builds many pages from one template and a data set, without thin pages |

### Get chosen

| Skill | What it does |
|---|---|
| `reviews` | Finds where reviews stall, writes the owner replies, and sets up the ask after every job |
| `first-screen-check` | Looks at the site on a phone the way a customer does: is the number, the promise and the proof on the first screen? |
| `landing-page` | Builds a page for one service and one offer, phone first |
| `direct-response-copy` | Writes headlines, offers and pages that get the call |
| `lead-magnet` | Makes the checklist, quote calculator or guide people trade an email for |

### Get the call

| Skill | What it does |
|---|---|
| `paid-ads` | Writes Google and Meta ads and the test plan for them |
| `google-ads-tracking` | Makes Google Ads count calls and form fills, so it bids on real leads |
| `ads-incrementality-check` | Runs a pause test against the phone log to see if the ads make the phone ring or only take credit |
| `meta-ads` | Sets up the Meta API, launches the campaign and proves the tracking fires |
| `speed-to-lead` | Finds missed calls and slow replies, then sets up the text-back and follow-up |
| `creative` | Makes ad images and short videos with AI image and video models |

### Bring them back

| Skill | What it does |
|---|---|
| `email-sequences` | Writes the welcome, quote follow-up, review ask and seasonal emails |
| `newsletter` | Plans and writes a newsletter people open |
| `performance-review` | Reads the numbers each month and says what to keep, cut and test |

### Win clients (for agencies and freelancers)

| Skill | What it does |
|---|---|
| `find-local-clients` | Picks a trade and a town, then ranks the businesses losing the most customers |
| `pitch-the-fix` | Finds the owner and writes a short email about one thing that's broken, with a fix you can sell |

Every skill can keep a separate folder per client. Tell `/start-here` "new client" and it sets one up.

### Market yourself

| Skill | What it does |
|---|---|
| `social-content` | Writes posts from your own best posts, not generic hooks |
| `long-form-article` | Plans and drafts a long guide with real numbers and named sources |
| `content-atomizer` | Turns one piece into posts for every platform |

## Found in the work

These skills came out of real campaigns. Three of the findings behind them:

- **The promise isn't on the page.** Most local businesses running ads that promise 24/7 or same-day service don't say it on the first screen of the page the ad opens (hundreds of local sites checked on a phone, Nov 2026). That's `first-screen-check`.
- **The ads were taking credit.** Google credited a Performance Max campaign with most of an account's conversions. Paused, the phone log didn't move. That's `ads-incrementality-check`.
- **One campaign beat three.** On the same small budget, one broad campaign brought leads at a fraction of the cost of the same money split three ways by city. That's in `paid-ads`.

## What we use

Every skill works with your agent's own web access. When you want more, this is the stack we run, and each skill names the pick at the step where it helps, with the free way first.

| Job | What we use | Cost |
|---|---|---|
| Web search for agents | Exa | Free tier, then pay as you go |
| Read, crawl and extract pages | Firecrawl | Free tier |
| Search volumes, SERPs, keyword data | DataForSEO | Pay as you go |
| Images and GIFs | GPT Image 2.6 (OpenAI) | Pay per image |
| Video | Seedance 2.5, through Higgsfield or Replicate | Pay per clip |
| Presenter and UGC-style ad video | Higgsfield Marketing Studio | Plans with credits |
| Voiceover | ElevenLabs | Free tier, then plans |
| Meta ads | Meta's official Ads MCP server and Ads CLI | Free with an ad account |
| Google Ads | Google Ads API | Free |
| Posting and scheduling | Zernio | Plans |
| Many data APIs, one key | treg | Pay per call |
| Search Console, Business Profile | Google | Free |
| Finding local businesses to pitch | boringfunnels (mine) | Free search, paid Pro |

Keys, setup and what each one unlocks: [TOOLS.md](TOOLS.md).

**About boringfunnels.** I make it, so every skill that mentions it says so on the same line. It never replaces the free path, and no skill needs it.

## Work with me

The skills are free. If you want more than the skills:

- **Have it built and run for you.** My team embeds with a few companies at a time and builds goal-tied AI agents that run their marketing. [boringmarketing.com](https://boringmarketing.com)
- **Learn to do it and sell it.** The [Boring Marketing community](https://www.skool.com/the-vibe-marketers) is where I teach marketers and agencies the whole playbook.
- **Find clients to use it on.** [boringfunnels.com](https://boringfunnels.com) finds local businesses losing customers (I make it).
- **Read the guides.** Long breakdowns on X at [@boringmarketer](https://x.com/boringmarketer).

## Updates

New skills land here first. Watch the repo to hear about them, and follow [@boringmarketer](https://x.com/boringmarketer) for the guides.

Found a bug or a skill that gave bad advice? Open an issue with what you asked and what it did.

## License

MIT. Use it for your business, your clients or your own product.
