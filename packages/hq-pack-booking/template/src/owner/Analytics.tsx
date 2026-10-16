// Bookings, cancels and no-shows by event type, host and week. Plain HTML bars.

import { useAsync } from "../lib/hooks.ts";
import { fillWeeks } from "../lib/owner-format.ts";
import { formatDateShort } from "../lib/time.ts";
import { useOwner } from "./context.ts";
import { Empty, Loadable, PageHead, Section } from "./parts.tsx";

interface Tally {
  key: string;
  bookings: number;
  canceled: number;
  noShows: number;
}

interface Data {
  from: string;
  to: string;
  totals: { bookings: number; canceled: number; noShows: number };
  byEventType: Tally[];
  byHost: Tally[];
  byWeek: Tally[];
}

const SERIES: { key: keyof Omit<Tally, "key">; label: string; cls: string }[] = [
  { key: "bookings", label: "Bookings", cls: "ow-s1" },
  { key: "canceled", label: "Canceled", cls: "ow-s2" },
  { key: "noShows", label: "No-shows", cls: "ow-s3" },
];

function niceMax(n: number): number {
  if (n <= 4) return 4;
  const pow = 10 ** Math.floor(Math.log10(n));
  const steps = [1, 2, 2.5, 5, 10];
  for (const s of steps) if (s * pow >= n) return s * pow;
  return 10 * pow;
}

/** Horizontal grouped bars: one row per key. HTML, so text keeps its real size. */
function HBars({ rows, label, name }: { rows: Tally[]; label: string; name: (k: string) => string }) {
  if (!rows.length) return <p class="ow-dim">No data yet.</p>;
  const max = niceMax(Math.max(...rows.map((r) => r.bookings)));
  return (
    <figure class="ow-chart">
      <div class="ow-hbars" aria-hidden="true">
        {rows.map((r) => (
          <div key={r.key} class="ow-hbar-row">
            <span class="ow-hbar-label" title={name(r.key)}>
              {name(r.key)}
            </span>
            <span class="ow-hbar-track">
              {SERIES.map((s) =>
                r[s.key] > 0 ? (
                  <span key={s.key} class="ow-hbar-line">
                    <span class={`ow-hbar ${s.cls}`} style={{ width: `${(r[s.key] / max) * 100}%` }} />
                    <span class="ow-hbar-value">{r[s.key]}</span>
                  </span>
                ) : null,
              )}
            </span>
          </div>
        ))}
        <div class="ow-hbar-row ow-hbar-axis">
          <span />
          <span class="ow-hbar-track">
            <span>0</span>
            <span>{max / 2}</span>
            <span>{max}</span>
          </span>
        </div>
      </div>
      <table class="bk-sr">
        <caption>{label}</caption>
        <thead>
          <tr>
            <th>Name</th>
            {SERIES.map((s) => (
              <th key={s.key}>{s.label}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.key}>
              <td>{name(r.key)}</td>
              <td>{r.bookings}</td>
              <td>{r.canceled}</td>
              <td>{r.noShows}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </figure>
  );
}

/** Vertical bars per week, bookings with canceled and no-shows beside them. */
function WeekBars({ rows }: { rows: Tally[] }) {
  if (!rows.length) return <p class="ow-dim">No data yet.</p>;
  const max = niceMax(Math.max(...rows.map((r) => r.bookings)));
  return (
    <figure class="ow-chart">
      <div class="ow-vbars" aria-hidden="true">
        <div class="ow-vbars-axis">
          <span>{max}</span>
          <span>{max / 2}</span>
          <span>0</span>
        </div>
        <div class="ow-vbars-plot">
          {rows.map((r, i) => (
            <div key={r.key} class="ow-vbar-week">
              <div class="ow-vbar-bars">
                {SERIES.map((s) => (
                  <span key={s.key} class={`ow-vbar ${s.cls}`} style={{ height: `${(r[s.key] / max) * 100}%` }} />
                ))}
              </div>
              <span class="ow-vbar-label">{rows.length <= 8 || (rows.length - 1 - i) % 2 === 0 ? formatDateShort(r.key).replace(/^\w+, /, "") : ""}</span>
            </div>
          ))}
        </div>
      </div>
      <table class="bk-sr">
        <caption>Bookings per week (week starting Monday)</caption>
        <thead>
          <tr>
            <th>Week</th>
            <th>Bookings</th>
            <th>Canceled</th>
            <th>No-shows</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.key}>
              <td>{r.key}</td>
              <td>{r.bookings}</td>
              <td>{r.canceled}</td>
              <td>{r.noShows}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </figure>
  );
}

export function Analytics() {
  const { call, session } = useOwner();
  const res = useAsync(() => call<Data>("/api/owner/analytics"), []);
  const evName = (k: string) => session.eventTypes?.find((e) => e.id === k)?.title ?? k;
  const hostName = (k: string) => session.hosts?.find((h) => h.id === k)?.name ?? k;
  return (
    <>
      <PageHead title="Analytics" sub="The last 12 weeks, by meeting start time." />
      <Loadable state={res} minHeight={420}>
        {(d) => (
          <>
            <div class="ow-tiles">
              <div class="ow-tile">
                <span class="ow-tile-label">Bookings</span>
                <span class="ow-tile-value">{d.totals.bookings}</span>
              </div>
              <div class="ow-tile">
                <span class="ow-tile-label">Canceled</span>
                <span class="ow-tile-value">{d.totals.canceled}</span>
                <span class="ow-tile-sub">{d.totals.bookings ? `${Math.round((d.totals.canceled / d.totals.bookings) * 100)}% of bookings` : "—"}</span>
              </div>
              <div class="ow-tile">
                <span class="ow-tile-label">No-shows</span>
                <span class="ow-tile-value">{d.totals.noShows}</span>
                <span class="ow-tile-sub">{d.totals.bookings ? `${Math.round((d.totals.noShows / d.totals.bookings) * 100)}% of bookings` : "—"}</span>
              </div>
            </div>
            <p class="ow-legend" aria-hidden="true">
              {SERIES.map((s) => (
                <span key={s.key}>
                  <span class={`ow-key ${s.cls}`} /> {s.label}
                </span>
              ))}
            </p>
            {d.totals.bookings === 0 ? (
              <Empty title="No bookings in this period">Charts fill in as people book.</Empty>
            ) : (
              <>
                <Section title="By week">
                  <WeekBars rows={fillWeeks(d.byWeek, d.from, d.to)} />
                </Section>
                <div class="ow-two">
                  <Section title="By event type">
                    <HBars rows={d.byEventType} label="Bookings by event type" name={evName} />
                  </Section>
                  <Section title="By host">
                    <HBars rows={d.byHost} label="Bookings by host" name={hostName} />
                  </Section>
                </div>
              </>
            )}
          </>
        )}
      </Loadable>
    </>
  );
}
