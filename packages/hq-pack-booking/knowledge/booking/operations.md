# Running HQ Booking

How the launcher sets up, builds, deploys and runs a company's booking app.
All commands are `bash core/packages/hq-pack-booking/scripts/hq-booking.sh
<command>`, run from the HQ root, for the session's company.

## Files

| Path | What it is |
|------|------------|
| `companies/{co}/booking/booking.yaml` | The settings. Holds the owner key's SHA-256, never the key. |
| `companies/{co}/booking/overrides/` | Optional component overrides layered over the template at build time. |
| `companies/{co}/booking/deploy.json` | Last deploy: app id and name, subdomain, URL, access mode, deploy id, time. No secrets. |
| `workspace/booking-builds/{co}/app/` | Working copy of the template, with npm packages, used to build. |
| `workspace/booking-builds/{co}/stage/` | What gets uploaded: `dist/`, `api/` and `db/migrations/`. |
| `workspace/booking-builds/{co}/build.json` | SHA-256 of the booking.yaml that was built, so deploy can refuse a stale build. |

## Owner key

The owner key signs every owner API call (`Authorization: Bearer <key>`).

- `setup` makes 32 random bytes (base64url), saves them in the company vault as
  `BOOKING_OWNER_KEY` by piping them to `hq secrets --company {co} set
  BOOKING_OWNER_KEY --from-stdin`, and only then writes the SHA-256 into
  `prototype.ownerKeySha256`. The key is never printed, put in a command line
  or written to disk.
- Running `setup` again keeps the key (and fixes the hash if it drifted).
  `setup --rotate-owner-key` makes a new key; the deployed app accepts it after
  the next `build` and `deploy`.
- `owner` and `dev` read the key at call time with
  `hq secrets exec --only BOOKING_OWNER_KEY --company {co} -- ...`, so only the
  child process sees it.
- The key is sent only to the URL in `deploy.json` or to a local dev server
  (`127.0.0.1`, `localhost`). Any other `--url` is refused.

## Build

`build` validates booking.yaml, copies the template (without `node_modules`
and `dist`) to `workspace/booking-builds/{co}/app/`, runs `npm ci` and
`npm run build` with `BOOKING_OVERRIDES_DIR` set to the company's overrides
folder (when it exists) and `BOOKING_CONFIG` set to booking.yaml, then runs
`npm run stage` (`dev/stage.ts`) into `stage/`. The stage bundles the checked
config as `api/_lib/booking.config.json` and refuses an upload over
hq-deploy's 100-file cap. An overrides folder that links into another
company is refused.

## Deploy

`deploy [--access password|company|public] [--password <pw>]
[--accept-database-billing]` uploads `stage/` as an hq-deploy `app` with a
database. It goes through the `/deploy` skill's helper scripts in
`.claude/skills/deploy/scripts/`:

1. `resolve-deploy-api.sh` for the hq-deploy address, `identity-resolve.sh`
   for the sign-in (signed out: stop and say "/hq-login").
2. `guardrails-check.sh stage/dist stage/api`, run from `stage/`, builds the
   tarball (with `db/migrations/`) and applies the caps.
3. Through `deploy-api-request.sh`, with `X-Org-Slug: {co}`:
   - `GET /api/apps`; `POST /api/apps {name, type: "app"}` when the app is new;
   - `GET /api/apps/{id}`;
   - `PATCH /api/apps/{id} {database: true, databaseBillingAcknowledged: true}`
     when the app has no database yet;
   - the access gate before the upload, so the pages are never live without
     it: `POST /access-mode {mode: "password", password}` (password),
     `PUT /access-policy {mode: "company", companyUid}` (company) or
     `POST /access-mode {mode: "public"}`;
   - `POST /api/apps/{id}/deploy` as multipart `type=app`,
     `database_billing_acknowledged=true`, `file=<tarball>`.
4. Writes `deploy.json` and prints the URL `https://{subdomain}.indigo-hq.com`.

Database billing follows the deploy skill: $10 a month per database app with
included usage. Companies listed in `HQ_DB_BILLING_EXEMPT_ORGS` (default
`indigo`) are not asked. Others get the terms in plain words and nothing is
created until they run `deploy --accept-database-billing`. A server answer of
`409 DATABASE_BILLING_ACK_REQUIRED` gets the same message.

Access defaults to a password for the prototype: sandbox data is not for the
public. A generated password is printed once and saved by the deploy skill's
`password-helper.sh` in `~/.hq/deploy-passwords.json`; redeploys keep it.
The sandbox app needs no secret bindings.

The app name is `booking-{co}` unless `prototype.appName` is set. Changing
booking.yaml after a build makes the next deploy stop with `build-stale`.

## Jobs

hq-deploy has no scheduler. `POST /api/owner/jobs/run` sends due reminders,
follow-ups and host briefs, retries webhooks, expires holds and approvals,
and runs the retention purge. `hq-booking.sh owner jobs-run` calls it once.

In production an Outpost scheduled job should call it every 5 minutes. To set
that up (only when the user agrees), run:

```
/schedule add "every 5 minutes, run bash core/packages/hq-pack-booking/scripts/hq-booking.sh owner jobs-run for {co} and alert me only if it fails"
```

and pick `BOOKING_OWNER_KEY` when `/schedule` asks which secrets the job needs.
The local dev server runs the same jobs every 30 seconds on its own.

## Local dev

`dev [--port 5180]` runs the app on this machine: the same API, the in-memory
store, sandbox providers, and the vault's owner key. Use `owner <command>
--url http://127.0.0.1:5180`. Data is lost when it stops.
