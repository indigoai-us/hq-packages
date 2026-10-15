import { useState } from "preact/hooks";
import { qs } from "../lib/api.ts";
import { useAsync } from "../lib/hooks.ts";
import { navigate } from "../lib/router.ts";
import { addDays, clockMinutes, formatClock, formatDateShort, wall, weekStart, zonedInstant, zoneLabel } from "../lib/time.ts";
import { Button, Icon, SandboxNote } from "../ui.tsx";
import { useOwner } from "./context.ts";
import { Loadable, PageHead } from "./parts.tsx";

interface CalEvent {
  id: string;
  kind: "busy" | "booking";
  title: string;
  start: string;
  end: string;
  status: string;
  bookingId: string | null;
  conference: unknown;
  attendees: unknown;
}

interface CalData {
  host: { id: string; name: string; timezone: string };
  busy: { start: string; end: string }[];
  events: CalEvent[];
}

const HOUR_PX = 44;

interface Block {
  key: string;
  day: number;
  top: number;
  height: number;
  label: string;
  time: string;
  kind: "busy" | "booking" | "canceled";
  bookingId: string | null;
}

function blocksFor(items: { key: string; start: string; end: string; label: string; kind: Block["kind"]; bookingId: string | null }[], days: string[], tz: string, startHour: number, hour12: boolean): Block[] {
  const out: Block[] = [];
  for (const it of items) {
    const a = wall(it.start, tz);
    const b = wall(it.end, tz);
    const day = days.indexOf(a.date);
    if (day < 0) continue;
    const startMin = clockMinutes(a.time);
    const endMin = b.date === a.date ? clockMinutes(b.time) : 24 * 60;
    const top = ((startMin - startHour * 60) / 60) * HOUR_PX;
    const height = Math.max(18, ((endMin - startMin) / 60) * HOUR_PX - 2);
    out.push({ key: it.key, day, top, height, label: it.label, time: `${formatClock(a.time, hour12)} – ${formatClock(b.time, hour12)}`, kind: it.kind, bookingId: it.bookingId });
  }
  return out;
}

export function Calendar() {
  const { call, session } = useOwner();
  const hosts = session.hosts ?? [];
  const [host, setHost] = useState(hosts[0]?.id ?? "");
  const tz = hosts.find((h) => h.id === host)?.timezone ?? "UTC";
  const [week, setWeek] = useState(() => weekStart(wall(Date.now(), tz).date));
  const days = Array.from({ length: 7 }, (_, i) => addDays(week, i));
  const res = useAsync(
    () =>
      host
        ? call<CalData>(`/api/owner/sandbox/calendar${qs({ host, from: new Date(zonedInstant(week, "00:00", tz)).toISOString(), to: new Date(zonedInstant(addDays(week, 7), "00:00", tz)).toISOString() })}`)
        : Promise.resolve(undefined as unknown as CalData),
    [host, week],
  );
  const today = wall(Date.now(), tz).date;

  return (
    <>
      <PageHead title="Calendar" sub="Busy time and booked events for one host, as the booking engine sees them.">
        <label class="ow-filter">
          <span>Host</span>
          <select class="bk-input" value={host} onChange={(e) => setHost((e.currentTarget as HTMLSelectElement).value)}>
            {hosts.map((h) => (
              <option key={h.id} value={h.id}>
                {h.name}
              </option>
            ))}
          </select>
        </label>
      </PageHead>
      <SandboxNote>Sandbox calendar. Real calendars connect through your HQ Google connection once Google approves booking access.</SandboxNote>
      <div class="ow-cal-bar">
        <div class="ow-cal-nav">
          <button type="button" class="bk-icon-btn" aria-label="Previous week" onClick={() => setWeek(addDays(week, -7))}>
            <Icon name="left" size={18} />
          </button>
          <button type="button" class="bk-icon-btn" aria-label="Next week" onClick={() => setWeek(addDays(week, 7))}>
            <Icon name="right" size={18} />
          </button>
          <Button size="sm" variant="ghost" onClick={() => setWeek(weekStart(today))}>
            This week
          </Button>
        </div>
        <p class="ow-cal-range" aria-live="polite">
          {formatDateShort(days[0] as string)} – {formatDateShort(days[6] as string)} · {zoneLabel(tz)}
        </p>
        <p class="ow-legend">
          <span class="ow-key ow-key-booking" /> Booked
          <span class="ow-key ow-key-busy" /> Busy on the host's calendar
        </p>
      </div>
      <Loadable state={res} minHeight={480}>
        {(d) => {
          if (!d) return <p class="ow-dim">Add a host to booking.yaml to see a calendar.</p>;
          const items = [
            ...d.events.map((e) => ({ key: e.id, start: e.start, end: e.end, label: e.kind === "booking" ? e.title : e.title || "Busy", kind: (e.kind === "busy" ? "busy" : e.status === "canceled" ? "canceled" : "booking") as Block["kind"], bookingId: e.bookingId })),
            ...d.busy.filter((b) => !d.events.some((e) => e.start === b.start && e.end === b.end)).map((b, i) => ({ key: `busy-${i}`, start: b.start, end: b.end, label: "Busy", kind: "busy" as const, bookingId: null })),
          ].filter((x) => x.kind !== "canceled");
          let startHour = 8;
          let endHour = 18;
          for (const it of items) {
            const a = wall(it.start, tz);
            const b = wall(it.end, tz);
            if (!days.includes(a.date)) continue;
            startHour = Math.min(startHour, Math.floor(clockMinutes(a.time) / 60));
            endHour = Math.max(endHour, b.date === a.date ? Math.ceil(clockMinutes(b.time) / 60) : 24);
          }
          const blocks = blocksFor(items, days, tz, startHour, true);
          const hours = Array.from({ length: endHour - startHour }, (_, i) => startHour + i);
          return (
            <div class="ow-cal-scroll">
              <div class="ow-cal" role="table" aria-label={`Week of ${formatDateShort(week)} for ${d.host.name}`}>
                <div class="ow-cal-head" role="row">
                  <span role="columnheader" class="ow-cal-corner" />
                  {days.map((day) => (
                    <span role="columnheader" key={day} class={`ow-cal-day${day === today ? " is-today" : ""}`}>
                      {formatDateShort(day)}
                    </span>
                  ))}
                </div>
                <div class="ow-cal-body" style={{ height: hours.length * HOUR_PX }}>
                  <div class="ow-cal-hours" aria-hidden="true">
                    {hours.map((h) => (
                      <span key={h} style={{ top: (h - startHour) * HOUR_PX }}>
                        {formatClock(`${h}:00`, true).replace(":00", "")}
                      </span>
                    ))}
                  </div>
                  {days.map((day, i) => (
                    <div key={day} class="ow-cal-col" role="cell" aria-label={formatDateShort(day)}>
                      {hours.map((h) => (
                        <span key={h} class="ow-cal-line" style={{ top: (h - startHour) * HOUR_PX }} />
                      ))}
                      {blocks
                        .filter((b) => b.day === i)
                        .map((b) =>
                          b.kind === "booking" && b.bookingId ? (
                            <button key={b.key} type="button" class="ow-block ow-block-booking" style={{ top: b.top, height: b.height }} onClick={() => navigate(`/owner/bookings/${encodeURIComponent(b.bookingId as string)}`)}>
                              <span class="ow-block-title">{b.label}</span>
                              <span class="ow-block-time">{b.time}</span>
                            </button>
                          ) : (
                            <div key={b.key} class="ow-block ow-block-busy" style={{ top: b.top, height: b.height }}>
                              <span class="ow-block-title">{b.label}</span>
                              <span class="ow-block-time">{b.time}</span>
                            </div>
                          ),
                        )}
                    </div>
                  ))}
                </div>
              </div>
            </div>
          );
        }}
      </Loadable>
    </>
  );
}
