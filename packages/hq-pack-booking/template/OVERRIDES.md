# Booking page overrides

A company can replace any named part of the booking pages, or add pages,
without editing the template. Overrides live in the company's folder,
`companies/{co}/booking/overrides/`, so a pack upgrade (which replaces the
template) leaves them in place. The launcher passes the folder to the build:

```bash
cd template
BOOKING_OVERRIDES_DIR=/path/to/companies/{co}/booking/overrides npm run build
```

## How it works

Pages import components as `@slots/<Name>`. The Vite plugin in
`build/layer-overrides.ts` resolves each one to `<overrides>/<Name>.tsx` when
that file exists, and to `src/components/<Name>.tsx` otherwise. Files in
`<overrides>/pages/` become extra routes: `pages/about.tsx` is `/about`,
`pages/team/sales.tsx` is `/team/sales`, `pages/team/index.tsx` is `/team`.

The build stops, naming the file, when:

- an override does not compile (`Override …/Header.tsx:2:20 failed to build: …`),
- an override imports something that does not exist,
- an override has no default export,
- a capitalised file does not match a component name (`…/Heder.tsx: there is no component called Heder`),
- a page file name is not lowercase letters, digits and dashes, or takes a
  route the booking pages use (`/`, `/owner…`, `/manage…`, `/l…`, `/route…`).

It never falls back to the template silently. Lowercase `.ts`/`.tsx` files and
subfolders other than `pages/` are helpers your overrides can import.

## Writing an override

- Export the component as `default`, with the same props as the component it
  replaces (below). TypeScript types are in `src/components/types.ts`.
- Import template code with `@booking/…` (for example
  `import TemplateHeader from "@booking/components/Header.tsx"` to wrap the
  original, or `import { Button, Icon } from "@booking/ui.tsx"`), and other
  components with `@slots/<Name>` so the company's other overrides still apply.
- Preact is bundled; write JSX as usual (`class` or `className` both work).
- Use the theme variables for every color, font and radius so the page follows
  booking.yaml `theme`: `--bk-bg`, `--bk-surface`, `--bk-text`, `--bk-muted`,
  `--bk-primary`, `--bk-on-primary`, `--bk-primary-text`, `--bk-primary-soft`,
  `--bk-accent`, `--bk-border`, `--bk-border-strong`, `--bk-hover`,
  `--bk-focus`, `--bk-danger`, `--bk-success`, `--bk-warning` (each with a
  `-soft` background), `--bk-font-heading`, `--bk-font-body`, `--bk-radius`,
  `--bk-radius-sm`, `--bk-radius-lg`.
- Keep it accessible: labels on inputs, visible focus, and no information in
  color alone.

A sample header (`examples/overrides/Header.tsx`) and page
(`examples/overrides/pages/about.tsx`) are in this template. Copy them into
the company folder to try them.

## Props each component receives

| Component | Props | Notes |
|---|---|---|
| `Header` | `config: PublicConfig`, `eventType?: EventType \| null` | Not shown inside embeds. `config.theme.logo` is the logo URL. |
| `Footer` | `config: PublicConfig` | `config.sandbox` is true in the prototype. |
| `EventList` | `eventTypes: EventType[]`, `hrefFor(ev): string` | Use `hrefFor` for links so prefill and utm parameters carry over. |
| `DurationPicker` | `durations: number[]`, `value: number`, `onChange(minutes)` | Render nothing when there is one duration. |
| `SlotPicker` | `eventType`, `duration`, `timezone`, `onTimezoneChange(tz)`, `hour12`, `onHour12Change(v)`, `hosts?: string[]`, `onSelect(slot: Slot)`, `pending?: string \| null`, `message?: string \| null`, `exclude?: string \| null`, `refreshKey?: number`, `initialDate?: string \| null` | Fetches `GET /api/slots` itself with `tz=timezone`. `pending` is the start being held; `message` is a plain notice such as "Someone just took that time"; `exclude` is the current time when rescheduling; re-fetch when `refreshKey` changes. |
| `LocationPicker` | `locations: LocationOption[]`, `value: number` (index), `onChange(index)`, `phone`, `onPhoneChange(v)`, `error?` | Ask for `phone` when the chosen location is `{ type: "phone", caller: "host" }`. |
| `IntakeForm` | `eventType`, `values: { name, email, guests, answers }`, `onChange(values)`, `errors: Record<string, string>`, `disabled?`, `prefill?` | Field ids must stay `bk-name`, `bk-email`, `bk-guests` and `bk-q-<questionId>` so errors can move focus to them. `errors` keys are `name`, `email`, `guests` or a question id. Checkbox answers are string arrays. |
| `Confirmation` | `result: { booking, manageUrl, icsUrl, redirectUrl }`, `eventType`, `timezone`, `hour12`, `embedded` | Show the time in `timezone`, the location or join link, the `.ics` link and the manage link. Use `target="_blank"` for the manage link when `embedded`. |
| `RoutingForm` | `form: { id, title, questions }`, `onSubmit(answers)`, `busy?`, `error?`, `initial?` | `onSubmit` gets API-shaped answers (numbers for number questions). The page evaluates them and moves on. |

Extra pages get `{ config: PublicConfig }`.

Shapes (`PublicConfig`, `EventType`, `Slot`, `Booking`…) are in
`src/lib/types.ts` and follow `API.md`.

## Embeds

`public/embed.js` (built to `dist/embed.js`) supports three modes from one
script tag:

```html
<div data-hq-booking="intro-call"></div>
<button data-hq-booking="intro-call" data-hq-mode="popup-button">Book a call</button>
<a href="https://APP/intro-call" data-hq-booking="intro-call" data-hq-mode="popup-text">Book a call</a>
<script src="https://APP/embed.js" async></script>
```

- Prefill with `data-hq-name`, `data-hq-email` and `data-hq-params="a_company=Acme"`.
  The host page's own `name`, `email`, `a_*` and `utm_*` URL parameters pass
  through, and utm values are saved on the booking and sent in webhooks.
- After a booking the page posts `{ type: "hq-booking:booked", bookingId, eventType, start }`
  to the host window, and embed.js fires a `hq-booking:booked` DOM event on the
  element and on `document`.
- When booking.yaml `embed.allowedOrigins` lists origins, the booking page
  refuses to render inside any other site and only posts messages to the
  embedding origin. An empty list allows any site (the prototype default).
  Browsers without `location.ancestorOrigins` (Firefox) rely on the
  `embed_origin` parameter embed.js adds, so treat the check as a guard
  against accidental embedding, not a security boundary.
- `examples/embed-test.html` is a host page for testing all three modes from
  another origin; the owner dashboard's Embed page has copy-paste snippets and
  a live preview.

## Theme

`GET /api/config/public` returns booking.yaml `theme`. `src/lib/theme.ts` turns
it into the variables above, raising contrast where a color would fail WCAG AA.
Named fonts (`fonts.heading`, `fonts.body`) load from Google Fonts; without
them the pages use a system serif for headings and the system sans for text.
When `theme.source` is `brand-pack`, the launcher is expected to resolve the
brand pack into `colors`, `fonts`, `radius` and `logo` before the build;
until then the neutral default applies.
