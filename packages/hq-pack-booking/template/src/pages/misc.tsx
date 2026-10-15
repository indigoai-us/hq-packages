// Small routes: event loader, single-use links, routing forms, not found.

import Footer from "@slots/Footer";
import Header from "@slots/Header";
import RoutingForm from "@slots/RoutingForm";
import { useState } from "preact/hooks";
import { useApp } from "../context.ts";
import { api, ApiError, errorMessage } from "../lib/api.ts";
import { useAsync } from "../lib/hooks.ts";
import { carryParams } from "../lib/params.ts";
import { navigate, useLocation } from "../lib/router.ts";
import type { EventType } from "../lib/types.ts";
import { ErrorState, Link, Loading } from "../ui.tsx";
import { EventPage } from "./EventPage.tsx";

function Shell({ children, narrow = true }: { children: preact.ComponentChildren; narrow?: boolean }) {
  const app = useApp();
  return (
    <div class="bk-page">
      {!app.embed.embedded && <Header config={app.config} />}
      <main id="main" class={`bk-main${narrow ? " bk-narrow" : ""}`}>
        {children}
      </main>
      <Footer config={app.config} />
    </div>
  );
}

export function Message({ title, text, home = true }: { title: string; text: string; home?: boolean }) {
  return (
    <Shell>
      <div class="bk-card bk-card-pad">
        <h1 class="bk-title">{title}</h1>
        <p class="bk-lede">{text}</p>
        {home && (
          <p>
            <Link href="/" class="bk-textlink">
              See all meeting types
            </Link>
          </p>
        )}
      </div>
    </Shell>
  );
}

export function EventRoute({ id }: { id: string }) {
  const app = useApp();
  const known = app.config.eventTypes.find((e) => e.id === id);
  const ev = useAsync(() => (known ? Promise.resolve(known) : api<{ eventType: EventType }>(`/api/event-types/${encodeURIComponent(id)}`).then((r) => r.eventType)), [id]);
  if (ev.loading && !ev.data) return <Shell narrow={false}>{<Loading label="Loading…" minHeight={420} />}</Shell>;
  if (ev.error || !ev.data) {
    return <Message title="We couldn't find that meeting" text="The link may be mistyped, or the meeting type was removed. Pick one of the open meeting types instead." />;
  }
  return <EventPage key={ev.data.id} eventType={ev.data} />;
}

export function LinkRoute({ token }: { token: string }) {
  const res = useAsync(
    () =>
      api<{ eventType: EventType; singleUse: boolean; expiresAt: string | null }>(`/api/links/${encodeURIComponent(token)}`).catch((e) => {
        if (e instanceof ApiError && (e.status === 410 || e.status === 404)) return { gone: e.status } as const;
        throw e;
      }),
    [token],
  );
  if (res.loading && !res.data) return <Shell narrow={false}>{<Loading label="Opening your link…" minHeight={420} />}</Shell>;
  if (res.error) return <Shell>{<ErrorState message={res.error} onRetry={res.reload} />}</Shell>;
  const d = res.data;
  if (!d || "gone" in d) {
    return <Message title="This link has expired or was already used." text="Booking links like this one work once or for a limited time. Ask the person who sent it for a new link." home={false} />;
  }
  return <EventPage eventType={d.eventType} link={token} linkNote={d.singleUse ? "This is a private, single-use booking link." : "This is a private booking link."} />;
}

export function RouteFormPage({ formId }: { formId: string }) {
  const app = useApp();
  const loc = useLocation();
  const form = app.config.routingForms.find((f) => f.id === formId);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!form) return <Message title="We couldn't find that form" text="Pick a meeting type from the list instead." />;
  const submit = async (answers: Record<string, unknown>) => {
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ target: { eventType?: string; hosts?: string[]; url?: string } }>(`/api/routing/${encodeURIComponent(form.id)}/evaluate`, { body: { answers } });
      const t = r.target;
      if (t.url) {
        const u = new URL(t.url, location.origin);
        if (u.protocol === "https:" || u.protocol === "http:") window.location.assign(u.href);
        return;
      }
      if (t.eventType) {
        const extra: Record<string, string> = {};
        for (const [k, v] of Object.entries(answers)) extra[`a_${k}`] = Array.isArray(v) ? v.join(",") : String(v);
        if (t.hosts?.length) extra.hosts = t.hosts.join(",");
        navigate(`/${encodeURIComponent(t.eventType)}${carryParams(loc.search, extra)}`);
        return;
      }
      setError("We couldn't pick a meeting from those answers. Choose one from the list instead.");
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <Shell>
      <div class="bk-card bk-card-pad">
        <h1 class="bk-title">{form.title}</h1>
        <p class="bk-lede">Answer {form.questions.length === 1 ? "this question" : "these questions"} and we'll show you the right meeting.</p>
        <RoutingForm form={form} onSubmit={submit} busy={busy} error={error} />
      </div>
    </Shell>
  );
}

export function NotFound() {
  return <Message title="This page doesn't exist" text="The address may be mistyped. Here are the meetings you can book." />;
}
