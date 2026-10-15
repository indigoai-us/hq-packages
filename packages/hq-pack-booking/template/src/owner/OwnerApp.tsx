// Owner dashboard at /owner. The owner key is kept in sessionStorage for
// this tab only and sent as a Bearer token.

import type { ComponentChildren } from "preact";
import { useEffect, useState } from "preact/hooks";
import { api, ApiError, errorMessage } from "../lib/api.ts";
import { companyName } from "../lib/labels.ts";
import { match, navigate, useLocation } from "../lib/router.ts";
import { themeVars } from "../lib/theme.ts";
import type { OwnerSession } from "../lib/types.ts";
import { Button, Field, Icon, Link, Notice } from "../ui.tsx";
import { Analytics } from "./Analytics.tsx";
import { Approvals } from "./Approvals.tsx";
import { BookingDetail, Bookings } from "./Bookings.tsx";
import { Calendar } from "./Calendar.tsx";
import { OwnerContext, type OwnerState } from "./context.ts";
import { Embed } from "./Embed.tsx";
import { Notifications, Outbox } from "./Sandbox.tsx";
import { Agents, Data, Jobs, Links, Webhooks } from "./Settings.tsx";

const KEY = "hq-booking:owner-key";

const NAV: { id: string; label: string; icon: string; group: string }[] = [
  { id: "bookings", label: "Bookings", icon: "list", group: "Bookings" },
  { id: "calendar", label: "Calendar", icon: "calendar", group: "Bookings" },
  { id: "approvals", label: "Approvals", icon: "shield", group: "Bookings" },
  { id: "analytics", label: "Analytics", icon: "chart", group: "Bookings" },
  { id: "outbox", label: "Outbox", icon: "mail", group: "Messages" },
  { id: "notifications", label: "Notifications", icon: "bell", group: "Messages" },
  { id: "links", label: "Links", icon: "link", group: "Sharing" },
  { id: "embed", label: "Embed", icon: "code", group: "Sharing" },
  { id: "agents", label: "Agents", icon: "key", group: "Access" },
  { id: "webhooks", label: "Webhooks", icon: "hook", group: "Access" },
  { id: "data", label: "Data", icon: "trash", group: "Maintenance" },
  { id: "jobs", label: "Jobs", icon: "play", group: "Maintenance" },
];

function readKey(): string | null {
  try {
    return sessionStorage.getItem(KEY);
  } catch {
    return null;
  }
}

function SignIn({ onKey, error }: { onKey: (k: string) => void; error: string | null }) {
  const [key, setKey] = useState("");
  return (
    <div class="ow-signin">
      <form
        class="bk-card bk-card-pad ow-signin-card"
        onSubmit={(e) => {
          e.preventDefault();
          if (key.trim()) onKey(key.trim());
        }}
      >
        <p class="ow-eyebrow">HQ Booking</p>
        <h1 class="bk-title">Owner sign-in</h1>
        <p class="bk-lede">Paste the owner key for this booking app. It stays in this browser tab only and is cleared when you close it.</p>
        <Field id="ow-key" label="Owner key" error={error}>
          <input id="ow-key" class="bk-input" type="password" autocomplete="off" spellcheck={false} value={key} onInput={(e) => setKey((e.currentTarget as HTMLInputElement).value)} aria-invalid={error ? "true" : undefined} aria-describedby={error ? "ow-key-error" : undefined} />
        </Field>
        <Button type="submit" variant="primary">
          Sign in
        </Button>
        <p class="bk-hint">The launcher prints the key when it creates the app (npm run dev prints one per run).</p>
      </form>
    </div>
  );
}

export function OwnerApp() {
  const loc = useLocation();
  const [key, setKey] = useState<string | null>(readKey);
  const [session, setSession] = useState<OwnerSession | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [checking, setChecking] = useState(!!key);

  useEffect(() => {
    const vars = themeVars({});
    for (const [k, v] of Object.entries(vars)) document.documentElement.style.setProperty(k, v);
    document.title = "Owner · HQ Booking";
  }, []);

  useEffect(() => {
    if (!key) return;
    setChecking(true);
    api<OwnerSession>("/api/owner/session", { token: key })
      .then((s) => {
        setSession(s);
        setError(null);
        try {
          sessionStorage.setItem(KEY, key);
        } catch {
          /* storage off */
        }
      })
      .catch((e) => {
        setSession(null);
        if (e instanceof ApiError && e.status === 401) {
          setError("That key didn't work. Check it and try again.");
          try {
            sessionStorage.removeItem(KEY);
          } catch {
            /* storage off */
          }
          setKey(null);
        } else setError(errorMessage(e));
      })
      .finally(() => setChecking(false));
  }, [key]);

  if (!key || (!session && !checking)) return <SignIn onKey={setKey} error={error} />;
  if (!session) return <div class="ow-signin"><p class="bk-loading" role="status">Signing in…</p></div>;

  const signOut = () => {
    try {
      sessionStorage.removeItem(KEY);
    } catch {
      /* storage off */
    }
    setKey(null);
    setSession(null);
    navigate("/owner");
  };

  const state: OwnerState = {
    session,
    call: <T,>(path: string, opts: { method?: string; body?: unknown } = {}) =>
      api<T>(path, { ...opts, token: key }).catch((e) => {
        if (e instanceof ApiError && e.status === 401) signOut();
        throw e;
      }),
  };

  const section = loc.path.split("/")[2] ?? "bookings";
  const detail = match("/owner/bookings/:id", loc.path);
  let body: ComponentChildren;
  if (detail) body = <BookingDetail id={detail.id as string} />;
  else if (section === "bookings") body = <Bookings />;
  else if (section === "calendar") body = <Calendar />;
  else if (section === "approvals") body = <Approvals />;
  else if (section === "analytics") body = <Analytics />;
  else if (section === "outbox") body = <Outbox />;
  else if (section === "notifications") body = <Notifications />;
  else if (section === "links") body = <Links />;
  else if (section === "embed") body = <Embed />;
  else if (section === "agents") body = <Agents />;
  else if (section === "webhooks") body = <Webhooks />;
  else if (section === "data") body = <Data />;
  else if (section === "jobs") body = <Jobs />;
  else body = <Notice>That section doesn't exist.</Notice>;

  const groups = [...new Set(NAV.map((n) => n.group))];
  return (
    <OwnerContext.Provider value={state}>
      <div class="ow">
        <aside class="ow-side">
          <div class="ow-brand">
            <span class="bk-monogram" aria-hidden="true">
              {companyName(session.company).slice(0, 1)}
            </span>
            <span>
              <span class="ow-brand-name">{companyName(session.company)}</span>
              <span class="ow-brand-sub">Booking owner</span>
            </span>
          </div>
          <nav class="ow-nav" aria-label="Owner sections">
            {groups.map((g) => (
              <div class="ow-nav-group" key={g}>
                <p class="ow-nav-label">{g}</p>
                {NAV.filter((n) => n.group === g).map((n) => (
                  <Link key={n.id} href={`/owner/${n.id}`} class={`ow-nav-item${section === n.id ? " is-active" : ""}`} aria-current={section === n.id ? "page" : undefined}>
                    <Icon name={n.icon} size={16} />
                    {n.label}
                  </Link>
                ))}
              </div>
            ))}
          </nav>
          <div class="ow-side-foot">
            {session.sandbox && (
              <p class="ow-env">
                <Icon name="sandbox" size={14} />
                Sandbox mode
              </p>
            )}
            <a class="ow-side-link" href="/" target="_blank" rel="noopener">
              <Icon name="external" size={14} />
              Open booking page
            </a>
            <button type="button" class="ow-side-link" onClick={signOut}>
              <Icon name="out" size={14} />
              Sign out
            </button>
          </div>
        </aside>
        <main id="main" class="ow-main">
          {body}
        </main>
      </div>
    </OwnerContext.Provider>
  );
}
