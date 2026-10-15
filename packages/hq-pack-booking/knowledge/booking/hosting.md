# Hosting the booking app on hq-deploy

What the booking app relies on in hq-deploy's `app` deploy type, read from
hq-deploy `origin/main` (`src/deploy/function/bundle.ts`, `function.ts`,
`front-door.ts`, `db-migrations.ts`, `register-app-principal.ts`,
`src/tenant-api/`, `docs/app-databases.md`), the `/deploy` skill ("App upload",
"C.2.8 Database apps", `scripts/guardrails-check.sh`) and
`core/knowledge/public/hq-core/app-databases.md`. Checked 2026-10-14.

## What gets uploaded

The deploy skill switches to the `app` type when the project root has an
`api/` directory with at least one `.ts` or `.js` file. Its tarball holds:

- the contents of the build output directory (`dist/` for a Vite app),
- the root `api/` directory,
- the root `db/migrations/` directory (`*.sql`).

Nothing else from the project is uploaded, `package.json` is not read, and no
npm packages are installed. The upload is capped at 100 files and 10 MB
gzipped. A root `migrations/` or `prisma/` directory, a `Dockerfile` or a
`serverless.yml` stops the deploy.

Consequences for this app:

- `api/` must be self-contained. `dev/stage.ts` copies the engine modules that
  have no dependencies (`shared/availability.ts`, `assignment.ts`, `time.ts`)
  into `api/_lib/shared/`, rewrites `api/_lib/engine.ts` to import them from
  there, and writes the checked `booking.yaml` as `api/_lib/booking.config.json`.
  `shared/config.ts` needs the `yaml` package, so the API imports only its types.
- The only packages the bundle can import are `node:*`, `@hq/db`, and what the
  shared Lambda layer provides (`hono`, `@aws-sdk/*`, `@smithy/*`,
  `@aws-crypto/*`, `pg`). The booking API uses `node:*` and `@hq/db` only.
- Static files are served from S3/CloudFront without invoking the function;
  `/api/*` goes to the function.

## Handler shape

Each file under `api/` is a module whose default export is

```ts
(req: Request, ctx: HandlerContext, pathParameters?: Record<string, string>) => Response | Promise<Response>
```

with `HandlerContext = { secrets, env, appId, companyUid }`:

- `secrets`: bound vault secrets by alias, resolved once per cold start.
  Server-side only. If the app has bindings and they cannot be resolved, every
  `/api/*` request fails closed with 503.
- `env`: the function environment minus `HQ_*` variables.
- `appId` (`HQ_APP_ID`) and `companyUid` (`HQ_COMPANY_UID`, `cmp_*`).

A module with no default export but a named `handler(event)` is wrapped as a
legacy API Gateway v2 Lambda handler. A handler that throws becomes a generic
500 `{"ok":false,"error":"internal_error"}`; the booking app catches its own
errors first and returns plain JSON errors.

## Routing

The bundler walks `api/` (skipping dotfiles, `*.d.ts`, `*.test.*` and
`*.spec.*`) and maps each file to a Hono route:

| File | Route |
|---|---|
| `api/foo.ts` | `/api/foo` |
| `api/index.ts` | `/api` |
| `api/orders/index.ts` | `/api/orders` |
| `api/orders/[id].ts` | `/api/orders/:id` (path parameter) |

Routes are mounted in sorted path order for all methods. `GET /api/_health`
belongs to the runtime and cannot be overridden. Two files that map to the
same route fail the build. There is no catch-all segment: `[...rest]` becomes
a literal parameter named `...rest` that matches one segment.

Every `.ts` file under `api/` is mounted, including helper modules. A helper
with no default export or `handler` is mounted as a route that answers 500.

The booking app therefore ships four handler files,
`api/[p1].ts`, `api/[p1]/[p2].ts`, `api/[p1]/[p2]/[p3].ts` and
`api/[p1]/[p2]/[p3]/[p4].ts`, one per path depth. Each passes the request to
the app's own router (`api/_lib/http.ts`), which matches the full path and
method and answers 404 or 405 itself. Because `[p1]` sorts before `_lib`, the
catch-alls are mounted first, so requests to `/api/_lib/...` reach the app's
router and get a 404 instead of the 500 a helper route would give. This also
keeps the upload small: 4 handler files, about 30 library files (including
the copied engine) and 22 migrations, leaving room under the 100-file cap for
the built pages. The bundler still imports every helper module (it treats
each as a route), so helpers must not export `default` or `handler`.

## Database (`database: true`)

- `@hq/db` is not an npm package. The bundler aliases it to
  `src/tenant-api/hq-db/index.ts` in hq-deploy's runtime source tree. It is
  imported in exactly one module here, `api/_lib/db.ts`; `types/hq-db.d.ts`
  describes the part used, and tests never load it.
- `getDb()` returns a pooled `pg` client signed in with short-lived IAM tokens
  for Aurora DSQL; `query(sql, params)` returns `{ rows, rowCount }`. bigint
  columns come back as strings.
- Environment: `HQ_DB_ENDPOINT`, `HQ_DB_ROLE`, `HQ_DB_SCHEMA` (set by the
  deploy; `search_path` is the app's schema) and `AWS_REGION`.
- Writes conflict optimistically. A transaction that loses a race fails at
  COMMIT with SQLSTATE `40001` (`OC000`). `OC001` follows a permission change
  (lock or unlock at the usage ceiling); `@hq/db` retries reads once and
  raises `CatalogChangedError` for writes. `api/_lib/sql-store.ts` runs every
  transaction itself (BEGIN/COMMIT on one pooled connection), retries `40001`
  up to 4 times with jittered backoff, and then reports a lost race as 409.
- Migrations: `db/migrations/*.sql` run in name order after the database is
  attached and before the new version goes live; a failure stops the deploy.
  The runner splits statements and runs each in its own transaction, records
  each file in `_hq_migrations`, and rejects `CREATE INDEX` without `ASYNC`,
  schema, role, grant and `search_path` statements. Rules followed here: one
  statement per file, `IF NOT EXISTS` so a re-run is harmless, no `SERIAL`
  (ids are made by the app), no foreign keys or triggers, no json columns
  (json is stored as text), and no transaction over 3,000 changed rows.
  `test/store.test.ts` checks the files match `api/_lib/tables.ts`.
- There is no SQL view for analytics; `/api/owner/analytics` aggregates in the
  function.
- Billing: $10 a month per database app with included usage; the deploy asks
  first unless the company is exempt (Indigo).

## Environment and identity

- Function environment: `HQ_APP_ID`, `APP_SUBDOMAIN`, `HQ_COMPANY_UID`,
  `HQ_SECRET_BINDINGS` (alias to vault secret name), the `HQ_DB_*` variables,
  and any non-secret environment the deploy sets. Handlers read `ctx.env`
  (no `HQ_*`) and `ctx.secrets`.
- Runtime: `nodejs20.x`, 256 MB, 15 second timeout, esbuild target `node20`,
  CommonJS output (`import.meta.url` is shimmed). Node 20 does not strip
  TypeScript, but esbuild compiles it, so the `.ts` import paths work.
- At deploy, the function's IAM role is registered with hq-pro as the app's
  `app_*` principal (`register-app-principal.ts`). Calls to hq-pro signed with
  SigV4 under that role can be checked against it. The hq-pro client here also
  accepts a per-app booking key bound as the secret `HQ_BOOKING_KEY`.
- Responses pass through one shared API Gateway HTTP API, which buffers them;
  streaming is not available.
- There is no scheduler. `POST /api/owner/jobs/run` does the due work
  (reminders, follow-ups, briefs, webhook retries, expired holds, retention)
  and is meant to be called by an Outpost scheduled job every few minutes.

## Secrets and settings the app reads

| Name | Where | Use |
|---|---|---|
| `BOOKING_TOKEN_KEY` | secret binding (optional) | HMAC key for manage-link tokens. Without it the key is derived from the owner key hash and the app id. |
| `HQ_BOOKING_KEY` | secret binding | Per-app key for the hq-pro booking route, when `prototype.provider` is `hqpro`. |
| webhook `signingSecret` names | secret bindings | Signing secrets for webhooks listed in `booking.yaml`. |
| `HQ_BOOKING_API_URL` | function env | Base URL of the hq-pro booking route, for `hqpro`. |
| `PUBLIC_BASE_URL` | function env (optional) | Origin used in email links, for custom domains. Defaults to the request origin. |

A public app with secret bindings stops at the deploy skill's advisory gate
until the deploy is confirmed; the sandbox prototype needs no bindings.

## Deploying

```bash
cd template
npm run stage -- /path/to/companies/{co}/booking/booking.yaml /tmp/booking-stage --dist dist
cd /tmp/booking-stage   # then /deploy with output dir dist and api dir api
```

Locally, `npm run dev` runs the same router on `node:http` with the in-memory
store and sandbox providers.
