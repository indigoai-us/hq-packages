import Footer from "@slots/Footer";
import Header from "@slots/Header";
import SlotPicker from "@slots/SlotPicker";
import { useEffect, useState } from "preact/hooks";
import { useApp } from "../context.ts";
import { api, errorMessage, qs } from "../lib/api.ts";
import { useAsync } from "../lib/hooks.ts";
import { locationTitle, nameList } from "../lib/labels.ts";
import { formatRange, zoneLabel } from "../lib/time.ts";
import type { Booking, EventType, Slot } from "../lib/types.ts";
import { Button, ErrorState, Field, Icon, Loading, Notice, SandboxNote } from "../ui.tsx";

type Mode = "view" | "cancel" | "reschedule";

function cutoffText(hours: number | null, verb: string): string {
  return hours
    ? `This booking can no longer be ${verb} online: changes close ${hours} hour${hours === 1 ? "" : "s"} before the start. Reply to your confirmation email to reach the host.`
    : `This booking can no longer be ${verb} online. Reply to your confirmation email to reach the host.`;
}

export function ManagePage({ id }: { id: string }) {
  const app = useApp();
  const token = new URLSearchParams(location.search).get("token") ?? "";
  const [mode, setMode] = useState<Mode>("view");
  const [done, setDone] = useState<string | null>(null);
  const booking = useAsync(() => api<{ booking: Booking }>(`/api/bookings/${encodeURIComponent(id)}${qs({ token })}`).then((r) => r.booking), [id, token]);

  useEffect(() => {
    if (done) document.getElementById("bk-manage-title")?.focus();
  }, [done]);

  const b = booking.data;
  return (
    <div class="bk-page">
      <Header config={app.config} />
      <main id="main" class="bk-main bk-narrow">
        {!token ? (
          <div class="bk-card bk-card-pad">
            <h1 class="bk-title">This link is missing its key</h1>
            <p class="bk-lede">Open the manage link from your confirmation email again. It ends with a token that lets you change the booking.</p>
          </div>
        ) : booking.loading && !b ? (
          <div class="bk-card bk-card-pad">
            <Loading label="Loading your booking…" minHeight={240} />
          </div>
        ) : booking.error || !b ? (
          <div class="bk-card bk-card-pad">
            <h1 class="bk-title">We couldn't open this booking</h1>
            <ErrorState message={booking.error ?? "Something went wrong."} onRetry={booking.reload} />
          </div>
        ) : mode === "reschedule" ? (
          <Reschedule
            booking={b}
            token={token}
            onCancel={() => setMode("view")}
            onDone={(nb) => {
              booking.set(nb);
              setMode("view");
              setDone("Your booking moved to the new time. An updated invitation is on its way.");
            }}
          />
        ) : (
          <div class="bk-card bk-card-pad">
            {done && (
              <Notice tone="success" live>
                {done}
              </Notice>
            )}
            <p class={`bk-status bk-status-${b.status}`}>{b.status === "canceled" ? "Canceled" : "Confirmed"}</p>
            <h1 id="bk-manage-title" class="bk-title" tabIndex={-1}>
              {b.eventType.title}
            </h1>
            <dl class="bk-details">
              <div>
                <dt>When</dt>
                <dd class={b.status === "canceled" ? "bk-struck" : undefined}>
                  {formatRange(b.start, b.end, app.timezone, app.hour12)}
                  <span class="bk-dd-sub">{zoneLabel(app.timezone, Date.parse(b.start))}</span>
                </dd>
              </div>
              {b.location && (
                <div>
                  <dt>Where</dt>
                  <dd>
                    {locationTitle(b.location)}
                    {(b.location.joinUrl ?? b.location.url) && b.status === "confirmed" && (
                      <span class="bk-dd-sub">
                        <a class="bk-break" href={b.location.joinUrl ?? b.location.url} target="_blank" rel="noopener noreferrer">
                          {b.location.joinUrl ?? b.location.url}
                        </a>
                      </span>
                    )}
                  </dd>
                </div>
              )}
              {b.hosts.length > 0 && (
                <div>
                  <dt>Who</dt>
                  <dd>{nameList(b.hosts.map((h) => h.name))}</dd>
                </div>
              )}
              {b.invitee && (
                <div>
                  <dt>Booked by</dt>
                  <dd>
                    {b.invitee.name}
                    <span class="bk-dd-sub">{b.invitee.email}</span>
                  </dd>
                </div>
              )}
              {b.cancelReason && (
                <div>
                  <dt>Reason</dt>
                  <dd>{b.cancelReason}</dd>
                </div>
              )}
            </dl>
            {b.location?.sandbox && b.status === "confirmed" && <SandboxNote>The join link is a placeholder in the prototype.</SandboxNote>}
            {b.status === "confirmed" && mode === "cancel" ? (
              <CancelForm
                booking={b}
                token={token}
                onBack={() => setMode("view")}
                onDone={(nb) => {
                  booking.set(nb);
                  setMode("view");
                  setDone("Your booking is canceled. The host has been told.");
                }}
              />
            ) : b.status === "confirmed" ? (
              <>
                <div class="bk-actions">
                  <a class="bk-btn bk-btn-secondary bk-btn-md" href={`/api/bookings/${encodeURIComponent(b.id)}/ics${qs({ token })}`} download>
                    <Icon name="download" size={16} />
                    Add to calendar
                  </a>
                  <Button onClick={() => setMode("reschedule")} disabled={!b.policy.canReschedule}>
                    Reschedule
                  </Button>
                  <Button variant="danger" onClick={() => setMode("cancel")} disabled={!b.policy.canCancel}>
                    Cancel booking
                  </Button>
                </div>
                {!b.policy.canCancel && !b.policy.canReschedule ? (
                  <p class="bk-hint">{cutoffText(b.policy.cancelCutoffHours ?? b.policy.rescheduleCutoffHours, "changed")}</p>
                ) : !b.policy.canCancel ? (
                  <p class="bk-hint">{cutoffText(b.policy.cancelCutoffHours, "canceled")}</p>
                ) : !b.policy.canReschedule ? (
                  <p class="bk-hint">{cutoffText(b.policy.rescheduleCutoffHours, "rescheduled")}</p>
                ) : null}
              </>
            ) : (
              <p class="bk-hint">
                Want to meet another time?{" "}
                <a class="bk-textlink" href={`/${encodeURIComponent(b.eventType.id)}`}>
                  Book a new time
                </a>
                .
              </p>
            )}
          </div>
        )}
      </main>
      <Footer config={app.config} />
    </div>
  );
}

function CancelForm({ booking, token, onBack, onDone }: { booking: Booking; token: string; onBack: () => void; onDone: (b: Booking) => void }) {
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [fieldError, setFieldError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const required = booking.policy.requireCancelReason;
  const submit = async (e: Event) => {
    e.preventDefault();
    if (required && !reason.trim()) {
      setFieldError("Please tell the host why you're canceling.");
      document.getElementById("bk-cancel-reason")?.focus();
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ booking: Booking }>(`/api/bookings/${encodeURIComponent(booking.id)}/cancel`, { body: { token, ...(reason.trim() ? { reason: reason.trim() } : {}) } });
      onDone(r.booking);
    } catch (err) {
      setError(errorMessage(err));
    } finally {
      setBusy(false);
    }
  };
  return (
    <form class="bk-cancel" onSubmit={submit} noValidate>
      <h2 class="bk-subtitle">Cancel this booking?</h2>
      <Field id="bk-cancel-reason" label={required ? "Reason" : "Reason (optional)"} required={required} error={fieldError} hint="The host sees this.">
        <textarea id="bk-cancel-reason" class="bk-input bk-textarea" rows={3} maxLength={500} value={reason} onInput={(e) => setReason((e.currentTarget as HTMLTextAreaElement).value)} aria-invalid={fieldError ? "true" : undefined} aria-describedby={`bk-cancel-reason-hint${fieldError ? " bk-cancel-reason-error" : ""}`} />
      </Field>
      {error && (
        <Notice tone="danger" live>
          {error}
        </Notice>
      )}
      <div class="bk-actions">
        <Button type="submit" variant="danger" busy={busy}>
          {busy ? "Canceling…" : "Yes, cancel it"}
        </Button>
        <Button variant="ghost" onClick={onBack}>
          Keep the booking
        </Button>
      </div>
    </form>
  );
}

function Reschedule({ booking, token, onCancel, onDone }: { booking: Booking; token: string; onCancel: () => void; onDone: (b: Booking) => void }) {
  const app = useApp();
  const ev = useAsync(() => api<{ eventType: EventType }>(`/api/event-types/${encodeURIComponent(booking.eventType.id)}`).then((r) => r.eventType), [booking.eventType.id]);
  const [picked, setPicked] = useState<Slot | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [refresh, setRefresh] = useState(0);
  const confirm = async () => {
    if (!picked) return;
    setBusy(true);
    setMessage(null);
    try {
      const r = await api<{ booking: Booking }>(`/api/bookings/${encodeURIComponent(booking.id)}/reschedule`, { body: { token, start: picked.start } });
      onDone(r.booking);
    } catch (e) {
      setMessage(errorMessage(e));
      setPicked(null);
      setRefresh((n) => n + 1);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div class="bk-card bk-booker is-pick">
      <aside class="bk-summary">
        <button type="button" class="bk-back" onClick={onCancel}>
          <Icon name="back" size={16} />
          Back to the booking
        </button>
        <h1 class="bk-event-heading">Pick a new time</h1>
        <p class="bk-summary-desc">
          {booking.eventType.title}, now {formatRange(booking.start, booking.end, app.timezone, app.hour12)}.
        </p>
        {picked && (
          <div class="bk-confirm-move" role="region" aria-label="New time">
            <p class="bk-fact-strong">
              Move to {formatRange(picked.start, picked.end, app.timezone, app.hour12)}?
            </p>
            <div class="bk-actions">
              <Button variant="primary" busy={busy} onClick={confirm}>
                {busy ? "Moving…" : "Confirm new time"}
              </Button>
              <Button variant="ghost" onClick={() => setPicked(null)}>
                Pick again
              </Button>
            </div>
          </div>
        )}
      </aside>
      <section class="bk-stage">
        <h2 class="bk-stage-title">Open times</h2>
        {ev.loading && !ev.data ? (
          <Loading label="Loading open times…" minHeight={360} />
        ) : ev.error || !ev.data ? (
          <ErrorState message={ev.error ?? "Something went wrong."} onRetry={ev.reload} />
        ) : (
          <SlotPicker
            eventType={ev.data}
            duration={booking.duration}
            timezone={app.timezone}
            onTimezoneChange={app.setTimezone}
            hour12={app.hour12}
            onHour12Change={app.setHour12}
            onSelect={setPicked}
            pending={busy ? picked?.start : null}
            message={message}
            exclude={booking.start}
            refreshKey={refresh}
          />
        )}
      </section>
    </div>
  );
}
