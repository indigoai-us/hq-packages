import Confirmation from "@slots/Confirmation";
import DurationPicker from "@slots/DurationPicker";
import Footer from "@slots/Footer";
import Header from "@slots/Header";
import IntakeForm from "@slots/IntakeForm";
import LocationPicker from "@slots/LocationPicker";
import SlotPicker from "@slots/SlotPicker";
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import type { IntakeValues } from "../components/types.ts";
import { postToParent, useApp } from "../context.ts";
import { api, ApiError, errorMessage } from "../lib/api.ts";
import { kindLabel, locationTitle, nameList } from "../lib/labels.ts";
import { answersForApi, looksLikeEmail, parseGuests, parsePrefill, parseUtm } from "../lib/params.ts";
import { useLocation } from "../lib/router.ts";
import { formatCountdown, formatDuration, formatRange, zoneLabel } from "../lib/time.ts";
import type { BookingResult, EventType, Hold, Slot } from "../lib/types.ts";
import { Avatar, Button, Icon, Notice } from "../ui.tsx";

type Step = "pick" | "details" | "done";

function HoldTimer({ expiresAt, onExpire }: { expiresAt: string; onExpire: () => void }) {
  const end = Date.parse(expiresAt);
  const [now, setNow] = useState(Date.now());
  const [spoken, setSpoken] = useState("");
  const fired = useRef(false);
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, []);
  const left = end - now;
  useEffect(() => {
    const s = Math.ceil(left / 1000);
    if (s === 60) setSpoken("One minute left to finish booking before this time is released.");
    if (s === 30) setSpoken("30 seconds left before this time is released.");
    if (left <= 0 && !fired.current) {
      fired.current = true;
      onExpire();
    }
  }, [Math.ceil(left / 1000)]);
  return (
    <p class={`bk-hold${left < 60_000 ? " is-low" : ""}`}>
      <Icon name="clock" size={14} />
      <span aria-hidden="true">Held for you for {formatCountdown(left)}</span>
      <span class="bk-sr">This time is held for you for 5 minutes while you fill in the form.</span>
      <span class="bk-sr" aria-live="assertive">
        {spoken}
      </span>
    </p>
  );
}

function emptyErrors(): Record<string, string> {
  return {};
}

export function EventPage({ eventType, link, linkNote }: { eventType: EventType; link?: string; linkNote?: string | null }) {
  const app = useApp();
  const loc = useLocation();
  const query = loc.query;
  const prefill = useMemo(() => parsePrefill(query, eventType.questions), [eventType.id]);
  const utm = useMemo(() => parseUtm(query), []);
  const hosts = useMemo(() => (query.get("hosts") ? (query.get("hosts") as string).split(",").filter(Boolean) : undefined), []);
  const initialDuration = Number(query.get("duration"));
  const [duration, setDuration] = useState(eventType.durations.includes(initialDuration) ? initialDuration : eventType.defaultDuration);
  const [step, setStep] = useState<Step>("pick");
  const [hold, setHold] = useState<Hold | null>(null);
  const [pending, setPending] = useState<string | null>(null);
  const [slotMessage, setSlotMessage] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [values, setValues] = useState<IntakeValues>({ name: prefill.name, email: prefill.email, guests: "", answers: prefill.answers });
  const [locationIndex, setLocationIndex] = useState(0);
  const [phone, setPhone] = useState("");
  const [errors, setErrors] = useState<Record<string, string>>(emptyErrors);
  const [formError, setFormError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<BookingResult | null>(null);
  const stageHeading = useRef<HTMLHeadingElement>(null);

  useEffect(() => {
    if (step !== "pick") requestAnimationFrame(() => (document.getElementById(step === "done" ? "bk-confirm-title" : "bk-details-title") as HTMLElement | null)?.focus());
  }, [step]);

  // Release the hold if the visitor leaves the page.
  useEffect(() => {
    if (!hold) return;
    const release = () => void fetch(`/api/holds/${encodeURIComponent(hold.holdId)}`, { method: "DELETE", keepalive: true }).catch(() => undefined);
    window.addEventListener("pagehide", release);
    return () => window.removeEventListener("pagehide", release);
  }, [hold]);

  const backToPick = (message: string | null) => {
    if (hold && step === "details") void api(`/api/holds/${encodeURIComponent(hold.holdId)}`, { method: "DELETE" }).catch(() => undefined);
    setHold(null);
    setPending(null);
    setStep("pick");
    setSlotMessage(message);
    setRefreshKey((k) => k + 1);
  };

  const selectSlot = async (slot: Slot) => {
    setPending(slot.start);
    setSlotMessage(null);
    try {
      const h = await api<Hold>("/api/holds", { body: { eventType: eventType.id, start: slot.start, duration, ...(link ? { link } : {}), ...(hosts ? { hosts } : {}) } });
      setHold(h);
      setErrors({});
      setFormError(null);
      setStep("details");
    } catch (e) {
      setSlotMessage(errorMessage(e));
      setRefreshKey((k) => k + 1);
    } finally {
      setPending(null);
    }
  };

  const location = eventType.locations[locationIndex];

  const validate = (): Record<string, string> => {
    const out: Record<string, string> = {};
    if (!values.name.trim()) out.name = "Enter your name.";
    if (!values.email.trim()) out.email = "Enter your email.";
    else if (!looksLikeEmail(values.email.trim())) out.email = "Enter an email like name@example.com.";
    for (const q of eventType.questions) {
      const v = values.answers[q.id];
      const empty = v === undefined || (Array.isArray(v) ? v.length === 0 : v.trim() === "");
      if (q.required && empty) out[q.id] = "Please answer this.";
      else if (!empty && q.type === "email" && typeof v === "string" && !looksLikeEmail(v.trim())) out[q.id] = "Enter an email like name@example.com.";
      else if (!empty && q.type === "number" && typeof v === "string" && !/^-?\d+(\.\d+)?$/.test(v.trim())) out[q.id] = "Enter a number.";
    }
    const guests = parseGuests(values.guests);
    if (guests.length > eventType.guestsMax) out.guests = `You can add up to ${eventType.guestsMax} guest${eventType.guestsMax === 1 ? "" : "s"}.`;
    else if (guests.some((g) => !looksLikeEmail(g))) out.guests = "Each guest needs an email address like name@example.com.";
    if (location?.type === "phone" && location.caller === "host" && !phone.trim()) out.phone = "Enter the number the host should call.";
    return out;
  };

  const submit = async (e: Event) => {
    e.preventDefault();
    if (!hold) return;
    const found = validate();
    setErrors(found);
    setFormError(null);
    const firstKey = Object.keys(found)[0];
    if (firstKey) {
      const id = firstKey === "name" || firstKey === "email" || firstKey === "guests" || firstKey === "phone" ? `bk-${firstKey}` : `bk-q-${firstKey}`;
      (document.getElementById(id) as HTMLElement | null)?.focus();
      return;
    }
    setSubmitting(true);
    try {
      const body = {
        holdId: hold.holdId,
        name: values.name.trim(),
        email: values.email.trim(),
        answers: answersForApi(eventType.questions, values.answers),
        guests: parseGuests(values.guests),
        location: location ? { type: location.type, ...(location.type === "phone" && location.caller === "host" ? { phone: phone.trim() } : {}) } : undefined,
        timezone: app.timezone,
        ...(Object.keys(utm).length ? { utm } : {}),
        ...(link ? { link } : {}),
      };
      const r = await api<BookingResult>("/api/bookings", { body });
      setResult(r);
      setHold(null);
      setStep("done");
      postToParent(app, { type: "hq-booking:booked", bookingId: r.booking.id, eventType: r.booking.eventType.id, start: r.booking.start, ...(r.redirectUrl ? { redirectUrl: r.redirectUrl } : {}) });
      if (r.redirectUrl && !app.embed.embedded) setTimeout(() => window.location.assign(r.redirectUrl as string), 1500);
    } catch (err) {
      if (err instanceof ApiError) {
        if (err.code === "hold-expired" || err.code === "slot-taken") {
          backToPick(err.message);
          return;
        }
        const byCode: Record<string, string> = { "too-many-guests": "guests", "bad-guests": "guests", "phone-required": "phone", "bad-email": "email" };
        const key = (err.details.question as string | undefined) ?? byCode[err.code] ?? (err.details.field as string | undefined);
        if (key && (key === "name" || key === "email" || key === "guests" || key === "phone" || eventType.questions.some((q) => q.id === key))) {
          setErrors({ [key]: err.message });
          return;
        }
      }
      setFormError(errorMessage(err));
    } finally {
      setSubmitting(false);
    }
  };

  const kind = kindLabel(eventType.kind, eventType.teamSize);
  const hostNames = eventType.hosts.map((h) => h.name);

  if (step === "done" && result) {
    return (
      <div class="bk-page">
        {!app.embed.embedded && <Header config={app.config} eventType={eventType} />}
        <main id="main" class="bk-main bk-narrow">
          <div class="bk-card bk-card-pad">
            <Confirmation result={result} eventType={eventType} timezone={app.timezone} hour12={app.hour12} embedded={app.embed.embedded} />
            {result.redirectUrl && !app.embed.embedded && <p class="bk-hint bk-center">Taking you to the next page…</p>}
          </div>
        </main>
        <Footer config={app.config} />
      </div>
    );
  }

  return (
    <div class="bk-page">
      {!app.embed.embedded && <Header config={app.config} eventType={eventType} />}
      <main id="main" class="bk-main">
        <div class={`bk-card bk-booker is-${step}`}>
          <aside class="bk-summary" aria-label="Meeting details">
            {hostNames.length > 0 && (
              <div class="bk-hosts">
                <span class="bk-avatars">
                  {hostNames.slice(0, 3).map((n) => (
                    <Avatar key={n} name={n} size={32} />
                  ))}
                </span>
                <span class="bk-host-names">{nameList(hostNames)}</span>
              </div>
            )}
            <h1 class="bk-event-heading">{eventType.title}</h1>
            {linkNote && <p class="bk-link-note">{linkNote}</p>}
            <ul class="bk-facts">
              <li>
                <Icon name="clock" size={16} />
                {step === "details" ? formatDuration(duration) : eventType.durations.map(formatDuration).join(" or ")}
              </li>
              <li>
                <Icon name={location?.type === "phone" ? "phone" : location?.type === "in-person" ? "pin" : "video"} size={16} />
                {eventType.locations.map(locationTitle).join(" or ")}
              </li>
              {kind && (
                <li>
                  <Icon name="users" size={16} />
                  {kind}
                  {eventType.seats ? `, up to ${eventType.seats} people` : ""}
                </li>
              )}
              {step === "details" && hold && (
                <li class="bk-fact-strong">
                  <Icon name="calendar" size={16} />
                  <span>
                    {formatRange(hold.start, hold.end, app.timezone, app.hour12)}
                    <span class="bk-dd-sub">{zoneLabel(app.timezone, Date.parse(hold.start))}</span>
                  </span>
                </li>
              )}
            </ul>
            {eventType.description && <p class="bk-summary-desc">{eventType.description}</p>}
            {step === "pick" && <DurationPicker durations={eventType.durations} value={duration} onChange={setDuration} />}
            {step === "details" && hold && <HoldTimer expiresAt={hold.expiresAt} onExpire={() => backToPick("Your hold ended, so the time was released. Pick a time again.")} />}
          </aside>

          <section class="bk-stage" aria-labelledby={step === "pick" ? "bk-pick-title" : "bk-details-title"}>
            {step === "pick" ? (
              <>
                <h2 id="bk-pick-title" class="bk-stage-title" ref={stageHeading}>
                  Pick a time
                </h2>
                <SlotPicker
                  eventType={eventType}
                  duration={duration}
                  timezone={app.timezone}
                  onTimezoneChange={app.setTimezone}
                  hour12={app.hour12}
                  onHour12Change={app.setHour12}
                  hosts={hosts}
                  onSelect={selectSlot}
                  pending={pending}
                  message={slotMessage}
                  refreshKey={refreshKey}
                  initialDate={query.get("date")}
                />
              </>
            ) : (
              <form class="bk-details-form" onSubmit={submit} noValidate>
                <button type="button" class="bk-back" onClick={() => backToPick(null)}>
                  <Icon name="back" size={16} />
                  Pick another time
                </button>
                <h2 id="bk-details-title" class="bk-stage-title" tabIndex={-1}>
                  Your details
                </h2>
                <LocationPicker locations={eventType.locations} value={locationIndex} onChange={setLocationIndex} phone={phone} onPhoneChange={setPhone} error={errors.phone} />
                <IntakeForm eventType={eventType} values={values} onChange={setValues} errors={errors} disabled={submitting} prefill={prefill} />
                {formError && (
                  <Notice tone="danger" live>
                    {formError}
                  </Notice>
                )}
                <div class="bk-submit-row">
                  <Button type="submit" variant="primary" busy={submitting}>
                    {submitting ? "Booking…" : "Confirm booking"}
                  </Button>
                  <p class="bk-hint">You'll get a confirmation email with a link to reschedule or cancel.</p>
                </div>
              </form>
            )}
          </section>
        </div>
      </main>
      <Footer config={app.config} />
    </div>
  );
}
