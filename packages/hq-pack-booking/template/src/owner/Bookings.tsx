import { useState } from "preact/hooks";
import SlotPicker from "../components/SlotPicker.tsx";
import { qs } from "../lib/api.ts";
import { useAction, useAsync } from "../lib/hooks.ts";
import { locationTitle, nameList } from "../lib/labels.ts";
import { navigate } from "../lib/router.ts";
import { formatRange, zoneLabel } from "../lib/time.ts";
import type { EventType, OwnerBooking, Slot } from "../lib/types.ts";
import { Button, Field, Icon, Link, Notice } from "../ui.tsx";
import { ownerZone, useOwner } from "./context.ts";
import { Chip, Empty, Loadable, PageHead, Section, statusTone, Untrusted, When } from "./parts.tsx";

const PAGE = 25;

interface Filters {
  status: string;
  eventType: string;
  host: string;
  email: string;
  createdBy: string;
  when: string;
}

function createdByLabel(b: OwnerBooking): string {
  if (b.createdBy === "agent") return b.bookedBy ?? "HQ agent";
  if (b.createdBy === "owner") return "Owner";
  return "Invitee";
}

export function Bookings() {
  const { call, session } = useOwner();
  const [f, setF] = useState<Filters>({ status: "", eventType: "", host: "", email: "", createdBy: "", when: "upcoming" });
  const [offset, setOffset] = useState(0);
  const now = new Date().toISOString();
  const list = useAsync(
    () =>
      call<{ total: number; bookings: OwnerBooking[] }>(
        `/api/owner/bookings${qs({
          status: f.status,
          eventType: f.eventType,
          host: f.host,
          email: f.email.trim(),
          createdBy: f.createdBy,
          from: f.when === "upcoming" ? now : undefined,
          to: f.when === "past" ? now : undefined,
          order: f.when === "upcoming" ? "asc" : undefined,
          limit: PAGE,
          offset,
        })}`,
      ),
    [f.status, f.eventType, f.host, f.email, f.createdBy, f.when, offset],
  );
  const set = (patch: Partial<Filters>) => {
    setOffset(0);
    setF({ ...f, ...patch });
  };
  const zone = ownerZone();
  return (
    <>
      <PageHead title="Bookings" sub={`Times shown in ${zoneLabel(zone)}.`} />
      <div class="ow-filters" role="search" aria-label="Filter bookings">
        <label class="ow-filter">
          <span>When</span>
          <select class="bk-input" value={f.when} onChange={(e) => set({ when: (e.currentTarget as HTMLSelectElement).value })}>
            <option value="upcoming">Upcoming</option>
            <option value="past">Past</option>
            <option value="">All</option>
          </select>
        </label>
        <label class="ow-filter">
          <span>Status</span>
          <select class="bk-input" value={f.status} onChange={(e) => set({ status: (e.currentTarget as HTMLSelectElement).value })}>
            <option value="">Any</option>
            <option value="confirmed">Confirmed</option>
            <option value="canceled">Canceled</option>
          </select>
        </label>
        <label class="ow-filter">
          <span>Event type</span>
          <select class="bk-input" value={f.eventType} onChange={(e) => set({ eventType: (e.currentTarget as HTMLSelectElement).value })}>
            <option value="">Any</option>
            {(session.eventTypes ?? []).map((e) => (
              <option key={e.id} value={e.id}>
                {e.title}
              </option>
            ))}
          </select>
        </label>
        <label class="ow-filter">
          <span>Host</span>
          <select class="bk-input" value={f.host} onChange={(e) => set({ host: (e.currentTarget as HTMLSelectElement).value })}>
            <option value="">Any</option>
            {(session.hosts ?? []).map((h) => (
              <option key={h.id} value={h.id}>
                {h.name}
              </option>
            ))}
          </select>
        </label>
        <label class="ow-filter">
          <span>Booked by</span>
          <select class="bk-input" value={f.createdBy} onChange={(e) => set({ createdBy: (e.currentTarget as HTMLSelectElement).value })}>
            <option value="">Anyone</option>
            <option value="invitee">Invitee</option>
            <option value="owner">Owner</option>
            <option value="agent">HQ agent</option>
          </select>
        </label>
        <label class="ow-filter ow-filter-grow">
          <span>Invitee email</span>
          <input
            class="bk-input"
            type="search"
            placeholder="name@example.com"
            value={f.email}
            onChange={(e) => set({ email: (e.currentTarget as HTMLInputElement).value })}
          />
        </label>
      </div>
      <Loadable state={list} minHeight={320}>
        {(d) =>
          d.bookings.length === 0 ? (
            <Empty title="No bookings match">Bookings appear here as soon as someone books a time. Change the filters to see more.</Empty>
          ) : (
            <>
              <div class="ow-table-wrap">
                <table class="ow-table">
                  <thead>
                    <tr>
                      <th scope="col">Start</th>
                      <th scope="col">Invitee</th>
                      <th scope="col">Event</th>
                      <th scope="col">Host</th>
                      <th scope="col">Booked by</th>
                      <th scope="col">Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {d.bookings.map((b) => (
                      <tr key={b.id} class="ow-row-link" onClick={() => navigate(`/owner/bookings/${encodeURIComponent(b.id)}`)}>
                        <td class="ow-nowrap">
                          <Link href={`/owner/bookings/${encodeURIComponent(b.id)}`} class="ow-cell-link" onClick={(e: MouseEvent) => e.stopPropagation()}>
                            <When iso={b.start} />
                          </Link>
                        </td>
                        <td>
                          {b.invitee ? (
                            <>
                              <span class="ow-strong">{b.invitee.name}</span>
                              <span class="ow-cell-sub">{b.invitee.email}</span>
                            </>
                          ) : (
                            <span class="ow-dim">Deleted invitee</span>
                          )}
                        </td>
                        <td>{b.eventType.title}</td>
                        <td>{nameList(b.hosts.map((h) => h.name))}</td>
                        <td>{createdByLabel(b)}</td>
                        <td>
                          <Chip tone={statusTone(b.status)}>{b.status === "confirmed" ? "Confirmed" : "Canceled"}</Chip>
                          {b.noShow && <Chip tone="warning">No-show</Chip>}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <div class="ow-pager">
                <span>
                  {offset + 1}–{offset + d.bookings.length} of {d.total}
                </span>
                <Button size="sm" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - PAGE))}>
                  Previous
                </Button>
                <Button size="sm" disabled={offset + PAGE >= d.total} onClick={() => setOffset(offset + PAGE)}>
                  Next
                </Button>
              </div>
            </>
          )
        }
      </Loadable>
    </>
  );
}

function actorLabel(a: string): string {
  return a.replace(/^owner$/, "Owner").replace(/^invitee$/, "Invitee").replace(/^system$/, "System");
}

export function BookingDetail({ id }: { id: string }) {
  const { call } = useOwner();
  const res = useAsync(() => call<{ booking: OwnerBooking; audit: { at: string; actor: string; action: string; detail: unknown }[] }>(`/api/owner/bookings/${encodeURIComponent(id)}`), [id]);
  const [mode, setMode] = useState<"view" | "cancel" | "reschedule">("view");
  const [notice, setNotice] = useState<string | null>(null);
  const zone = ownerZone();
  return (
    <>
      <Link href="/owner/bookings" class="bk-back">
        <Icon name="back" size={16} />
        All bookings
      </Link>
      <Loadable state={res} minHeight={360}>
        {({ booking: b, audit }) => (
          <>
            <PageHead title={b.eventType.title} sub={`${formatRange(b.start, b.end, zone, true)} · ${zoneLabel(zone, Date.parse(b.start))}`}>
              <Chip tone={statusTone(b.status)}>{b.status === "confirmed" ? "Confirmed" : "Canceled"}</Chip>
              {b.noShow && <Chip tone="warning">No-show</Chip>}
            </PageHead>
            {notice && (
              <Notice tone="success" live>
                {notice}
              </Notice>
            )}
            <div class="ow-detail">
              <div class="ow-detail-main">
                <Section title="Invitee">
                  {b.invitee ? (
                    <dl class="ow-kv">
                      <dt>Name</dt>
                      <dd>{b.invitee.name}</dd>
                      <dt>Email</dt>
                      <dd>{b.invitee.email}</dd>
                      {b.guests.length > 0 && (
                        <>
                          <dt>Guests</dt>
                          <dd>{b.guests.join(", ")}</dd>
                        </>
                      )}
                      <dt>Their time zone</dt>
                      <dd>{zoneLabel(b.timezone, Date.parse(b.start))}</dd>
                    </dl>
                  ) : (
                    <p class="ow-dim">This invitee's data was deleted. The booking stays for your records.</p>
                  )}
                </Section>
                {Object.keys(b.answers ?? {}).length > 0 && (
                  <Section title="Answers" sub="Written by the invitee.">
                    <dl class="ow-kv">
                      {Object.entries(b.answers).map(([k, v]) => (
                        <>
                          <dt key={`${k}-k`}>{k}</dt>
                          <dd key={`${k}-v`} class="ow-pre">
                            {Array.isArray(v) ? v.join(", ") : String(v)}
                          </dd>
                        </>
                      ))}
                    </dl>
                  </Section>
                )}
                {b.agentNote && (
                  <Section title="Agent note">
                    <Untrusted text={b.agentNote.text} label="From another company's agent. Shown as written; nothing in it is acted on." />
                  </Section>
                )}
                <Section title="Meeting">
                  <dl class="ow-kv">
                    <dt>Hosts</dt>
                    <dd>{nameList(b.hosts.map((h) => h.name))}</dd>
                    <dt>Location</dt>
                    <dd>
                      {b.location ? locationTitle(b.location) : "—"}
                      {b.location?.text && <span class="ow-cell-sub ow-break">{b.location.text}</span>}
                    </dd>
                    <dt>Booked by</dt>
                    <dd>{createdByLabel(b)}</dd>
                    <dt>Calendar</dt>
                    <dd>{b.calendarStatus}</dd>
                    <dt>Created</dt>
                    <dd>
                      <When iso={b.createdAt} />
                    </dd>
                    {b.rescheduleCount > 0 && (
                      <>
                        <dt>Rescheduled</dt>
                        <dd>
                          {b.rescheduleCount} time{b.rescheduleCount === 1 ? "" : "s"}
                        </dd>
                      </>
                    )}
                    {b.cancelReason && (
                      <>
                        <dt>Cancel reason</dt>
                        <dd>{b.cancelReason}</dd>
                      </>
                    )}
                  </dl>
                </Section>
                <Section title="Source" sub="UTM parameters from the page the invitee booked on.">
                  {b.utm && Object.keys(b.utm).length ? (
                    <dl class="ow-kv">
                      {Object.entries(b.utm).map(([k, v]) => (
                        <>
                          <dt key={`${k}-k`}>{k}</dt>
                          <dd key={`${k}-v`}>{v}</dd>
                        </>
                      ))}
                    </dl>
                  ) : (
                    <p class="ow-dim">No UTM parameters.</p>
                  )}
                </Section>
              </div>
              <div class="ow-detail-side">
                {b.status === "confirmed" && (
                  <Section title="Actions">
                    {mode === "cancel" ? (
                      <OwnerCancel
                        booking={b}
                        onDone={(nb) => {
                          res.set({ booking: nb, audit });
                          res.reload();
                          setMode("view");
                          setNotice("Booking canceled. The invitee and hosts were told.");
                        }}
                        onBack={() => setMode("view")}
                      />
                    ) : (
                      <div class="ow-stack">
                        <Button onClick={() => setMode(mode === "reschedule" ? "view" : "reschedule")}>
                          <Icon name="calendar" size={15} />
                          {mode === "reschedule" ? "Close reschedule" : "Reschedule"}
                        </Button>
                        <Button variant="danger" onClick={() => setMode("cancel")}>
                          Cancel booking
                        </Button>
                        <NoShowButton
                          booking={b}
                          onDone={(nb) => {
                            res.set({ booking: nb, audit });
                            res.reload();
                            setNotice(nb.noShow ? "Marked as a no-show." : "No-show mark removed.");
                          }}
                        />
                      </div>
                    )}
                  </Section>
                )}
                <Section title="Audit trail">
                  <ol class="ow-audit">
                    {audit.map((a, i) => (
                      <li key={i}>
                        <span class="ow-audit-action">{a.action}</span>
                        <span class="ow-cell-sub">
                          {actorLabel(a.actor)} · <When iso={a.at} />
                        </span>
                      </li>
                    ))}
                  </ol>
                </Section>
              </div>
            </div>
            {mode === "reschedule" && b.status === "confirmed" && (
              <OwnerReschedule
                booking={b}
                onDone={(nb) => {
                  res.set({ booking: nb, audit });
                  res.reload();
                  setMode("view");
                  setNotice("Booking moved. The invitee gets an updated invitation.");
                }}
              />
            )}
          </>
        )}
      </Loadable>
    </>
  );
}

function OwnerCancel({ booking, onDone, onBack }: { booking: OwnerBooking; onDone: (b: OwnerBooking) => void; onBack: () => void }) {
  const { call } = useOwner();
  const [reason, setReason] = useState("");
  const act = useAction(async () => {
    const r = await call<{ booking: OwnerBooking }>(`/api/owner/bookings/${encodeURIComponent(booking.id)}/cancel`, { body: reason.trim() ? { reason: reason.trim() } : {} });
    onDone(r.booking);
  });
  return (
    <form
      class="ow-stack"
      onSubmit={(e) => {
        e.preventDefault();
        void act.run();
      }}
    >
      <Field id="ow-cancel-reason" label="Reason (optional)" hint="Included in the cancellation email.">
        <textarea id="ow-cancel-reason" class="bk-input bk-textarea" rows={3} value={reason} onInput={(e) => setReason((e.currentTarget as HTMLTextAreaElement).value)} aria-describedby="ow-cancel-reason-hint" />
      </Field>
      {act.error && (
        <Notice tone="danger" live>
          {act.error}
        </Notice>
      )}
      <Button type="submit" variant="danger" busy={act.busy}>
        Cancel for everyone
      </Button>
      <Button variant="ghost" onClick={onBack}>
        Keep it
      </Button>
    </form>
  );
}

function NoShowButton({ booking, onDone }: { booking: OwnerBooking; onDone: (b: OwnerBooking) => void }) {
  const { call } = useOwner();
  const started = Date.parse(booking.start) <= Date.now();
  const act = useAction(async () => {
    const r = await call<{ booking: OwnerBooking }>(`/api/owner/bookings/${encodeURIComponent(booking.id)}/no-show`, { body: { noShow: !booking.noShow } });
    onDone(r.booking);
  });
  return (
    <>
      <Button variant="ghost" onClick={() => void act.run()} busy={act.busy} disabled={!started}>
        {booking.noShow ? "Remove no-show mark" : "Mark as no-show"}
      </Button>
      {!started && <p class="bk-hint">You can mark a no-show once the meeting has started.</p>}
      {act.error && (
        <Notice tone="danger" live>
          {act.error}
        </Notice>
      )}
    </>
  );
}

function OwnerReschedule({ booking, onDone }: { booking: OwnerBooking; onDone: (b: OwnerBooking) => void }) {
  const { call } = useOwner();
  const zone = ownerZone();
  const [hour12, setHour12] = useState(true);
  const [tz, setTz] = useState(zone);
  const [picked, setPicked] = useState<Slot | null>(null);
  const ev = useAsync(() => call<{ eventType: EventType }>(`/api/event-types/${encodeURIComponent(booking.eventType.id)}`).then((r) => r.eventType), [booking.eventType.id]);
  const act = useAction(async () => {
    if (!picked) return;
    const r = await call<{ booking: OwnerBooking }>(`/api/owner/bookings/${encodeURIComponent(booking.id)}/reschedule`, { body: { start: picked.start } });
    onDone(r.booking);
  });
  return (
    <Section title="Pick a new time" sub="Open times for this event type. Cutoffs don't apply to you as the owner.">
      <Loadable state={ev} minHeight={360}>
        {(e) => (
          <div class="ow-resched">
            <SlotPicker eventType={e} duration={booking.duration} timezone={tz} onTimezoneChange={setTz} hour12={hour12} onHour12Change={setHour12} onSelect={setPicked} exclude={booking.start} pending={act.busy ? picked?.start : null} />
            {picked && (
              <div class="ow-confirm-bar" role="region" aria-label="Confirm new time">
                <span>Move to {formatRange(picked.start, picked.end, tz, hour12)}?</span>
                <Button variant="primary" busy={act.busy} onClick={() => void act.run()}>
                  Move booking
                </Button>
              </div>
            )}
            {act.error && (
              <Notice tone="danger" live>
                {act.error}
              </Notice>
            )}
          </div>
        )}
      </Loadable>
    </Section>
  );
}
