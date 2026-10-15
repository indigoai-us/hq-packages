// Entry used by the api/ handler files on hq-deploy. Builds the app once per
// Lambda container: the bundled booking config, the SQL store over @hq/db,
// and the providers named in the config. Thin by design; the logic it calls
// is tested through app.ts.

import { buildServices, createBookingApp, startupFailure, type BookingApp } from "./app.ts";
import configJson from "./booking.config.json" with { type: "json" };
import { createDatabase } from "./db.ts";
import type { BookingConfig } from "./engine.ts";
import { SqlStore } from "./sql-store.ts";

/** The context hq-deploy's runtime passes to every handler. */
export interface HandlerContext {
  secrets: Record<string, string>;
  env: Record<string, string>;
  appId: string;
  companyUid: string;
}

let app: Promise<BookingApp> | undefined;

function build(ctx: HandlerContext): Promise<BookingApp> {
  return Promise.resolve().then(() =>
    createBookingApp(
      buildServices({
        config: configJson as unknown as BookingConfig,
        store: new SqlStore(createDatabase()),
        secrets: ctx.secrets,
        env: ctx.env,
        appId: ctx.appId,
      }),
    ),
  );
}

export async function serveDeployed(req: Request, ctx: HandlerContext): Promise<Response> {
  app ??= build(ctx).catch((err) => {
    app = undefined;
    throw err;
  });
  try {
    return await (await app).handle(req);
  } catch (err) {
    return startupFailure(err);
  }
}
