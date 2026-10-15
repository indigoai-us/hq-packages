import extraPages from "virtual:booking-pages";
import { render } from "preact";
import { useEffect, useMemo, useState } from "preact/hooks";
import { AppContext, type AppState } from "./context.ts";
import { api } from "./lib/api.ts";
import { useAsync } from "./lib/hooks.ts";
import { embedAllowed, parseEmbed } from "./lib/params.ts";
import { match, useLocation } from "./lib/router.ts";
import { fontStylesheet, themeVars } from "./lib/theme.ts";
import { isValidZone, prefersHour12 } from "./lib/time.ts";
import type { PublicConfig } from "./lib/types.ts";
import { OwnerApp } from "./owner/OwnerApp.tsx";
import { CompanyPage } from "./pages/CompanyPage.tsx";
import { ManagePage } from "./pages/ManagePage.tsx";
import { EventRoute, LinkRoute, Message, NotFound, RouteFormPage } from "./pages/misc.tsx";
import "./styles.css";
import { ErrorState, Loading } from "./ui.tsx";

function applyTheme(config: PublicConfig | null): void {
  const vars = themeVars(config?.theme ?? {});
  const root = document.documentElement;
  for (const [k, v] of Object.entries(vars)) root.style.setProperty(k, v);
  root.style.colorScheme = vars["--bk-scheme"] ?? "light";
  const href = config ? fontStylesheet(config.theme) : null;
  if (href && !document.querySelector(`link[data-bk-font]`)) {
    const l = document.createElement("link");
    l.rel = "stylesheet";
    l.href = href;
    l.dataset.bkFont = "1";
    document.head.appendChild(l);
  }
}

function readPref(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writePref(key: string, v: string): void {
  try {
    localStorage.setItem(key, v);
  } catch {
    /* storage off */
  }
}

function initialZone(): string {
  const q = new URLSearchParams(location.search).get("tz");
  if (q && isValidZone(q)) return q;
  const saved = readPref("hq-booking:tz");
  if (saved && isValidZone(saved)) return saved;
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

function initialHour12(): boolean {
  const q = new URLSearchParams(location.search).get("hour");
  if (q === "12" || q === "24") return q === "12";
  const saved = readPref("hq-booking:hour");
  if (saved === "12" || saved === "24") return saved === "12";
  return prefersHour12(navigator.language || "en-US");
}

function useEmbedResize(enabled: boolean, origin: string | null) {
  useEffect(() => {
    if (!enabled || window.parent === window) return;
    let last = 0;
    const post = () => {
      const h = Math.ceil(document.documentElement.scrollHeight);
      if (h === last) return;
      last = h;
      window.parent.postMessage({ type: "hq-booking:resize", height: h }, origin ?? "*");
    };
    const ro = new ResizeObserver(post);
    ro.observe(document.body);
    post();
    return () => ro.disconnect();
  }, [enabled, origin]);
}

function PublicApp() {
  const loc = useLocation();
  const embed = useMemo(() => parseEmbed(location.search), []);
  const [timezone, setTz] = useState(initialZone);
  const [hour12, setH12] = useState(initialHour12);
  const config = useAsync((signal) => api<PublicConfig>("/api/config/public", { signal }), []);
  useEffect(() => {
    if (config.data) applyTheme(config.data);
  }, [config.data]);
  useEffect(() => {
    document.documentElement.classList.toggle("is-embedded", embed.embedded);
  }, [embed.embedded]);
  useEmbedResize(embed.embedded, embed.origin);

  if (config.loading && !config.data) {
    return (
      <div class="bk-page">
        <main class="bk-main bk-narrow">
          <Loading label="Loading booking page…" minHeight={320} />
        </main>
      </div>
    );
  }
  if (config.error || !config.data) {
    return (
      <div class="bk-page">
        <main class="bk-main bk-narrow">
          <div class="bk-card bk-card-pad">
            <h1 class="bk-title">The booking page didn't load</h1>
            <ErrorState message={config.error ?? "Something went wrong."} onRetry={config.reload} />
          </div>
        </main>
      </div>
    );
  }

  const state: AppState = {
    config: config.data,
    embed,
    timezone,
    setTimezone: (tz) => {
      setTz(tz);
      writePref("hq-booking:tz", tz);
    },
    hour12,
    setHour12: (v) => {
      setH12(v);
      writePref("hq-booking:hour", v ? "12" : "24");
    },
  };

  if (embed.embedded) {
    const ancestors = (location as unknown as { ancestorOrigins?: DOMStringList }).ancestorOrigins;
    const parentOrigin = ancestors?.length ? ancestors[0] ?? null : embed.origin;
    if (!embedAllowed(parentOrigin, location.origin, config.data.embed.allowedOrigins)) {
      return (
        <AppContext.Provider value={{ ...state, embed: { ...embed, embedded: false } }}>
          <Message title="This booking page can't be shown here" text="The site owner hasn't allowed this booking page to be embedded on this website. Open it directly instead." home={false} />
        </AppContext.Provider>
      );
    }
  }

  return <AppContext.Provider value={state}>{route(loc.path, config.data)}</AppContext.Provider>;
}

function route(path: string, config: PublicConfig) {
  if (path === "/") return <CompanyPage />;
  for (const p of extraPages) if (p.route === path) return <p.component config={config} />;
  let m = match("/manage/:id", path);
  if (m) return <ManagePage id={m.id as string} />;
  m = match("/l/:token", path);
  if (m) return <LinkRoute token={m.token as string} />;
  m = match("/route/:formId", path);
  if (m) return <RouteFormPage formId={m.formId as string} />;
  m = match("/:eventTypeId", path);
  if (m) return <EventRoute id={m.eventTypeId as string} />;
  return <NotFound />;
}

function Root() {
  const loc = useLocation();
  if (loc.path === "/owner" || loc.path.startsWith("/owner/")) return <OwnerApp />;
  return <PublicApp />;
}

applyTheme(null);
render(<Root />, document.getElementById("app") as HTMLElement);
