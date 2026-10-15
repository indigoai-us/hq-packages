// Bookings, cancels and no-shows by event type, host and week. Plain SVG.

import { useAsync } from "../lib/hooks.ts";
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

/** Horizontal grouped bars: one row per key. */
function HBars({ rows, label, name }: { rows: Tally[]; label: string; name: (k: string) => string }) {
  if (!rows.length) return <p class="ow-dim">No data yet.</p>;
  const max = niceMax(Math.max(...rows.map((r) => r.bookings)));
  const labelW = 150;
  const width = 560;
  const barW = width - labelW - 40;
  const rowH = 46;
  const height = rows.length * rowH + 24;
  return (
    <figure class="ow-chart">
      <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={label} preserveAspectRatio="xMinYMin meet">
        {[0, 0.5, 1].map((t) => (
          <g key={t}>
            <line x1={labelW + t * barW} x2={labelW + t * barW} y1={0} y2={height - 20} class="ow-grid" />
            <text x={labelW + t * barW} y={height - 6} class="ow-axis" text-anchor="middle">
              {Math.round(t * max)}
            </text>
          </g>
        ))}
        {rows.map((r, i) => {
          const y = i * rowH + 6;
          return (
            <g key={r.key}>
              <text x={0} y={y + 16} class="ow-label">
                {name(r.key).length > 20 ? `${name(r.key).slice(0, 19)}…` : name(r.key)}
              </text>
              {SERIES.map((s, j) => {
                const v = r[s.key];
                return (
                  <g key={s.key}>
                    <rect x={labelW} y={y + j * 11} width={Math.max(v ? 2 : 0, (v / max) * barW)} height={9} rx={2} class={s.cls} />
                    {v > 0 && (
                      <text x={labelW + (v / max) * barW + 6} y={y + j * 11 + 8} class="ow-value">
                        {v}
                      </text>
                    )}
                  </g>
                );
              })}
            </g>
          );
        })}
      </svg>
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
  const width = 720;
  const height = 220;
  const left = 28;
  const plotH = height - 40;
  const slot = (width - left) / rows.length;
  const bw = Math.min(10, (slot - 8) / 3);
  return (
    <figure class="ow-chart">
      <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Bookings per week" preserveAspectRatio="xMinYMin meet">
        {[0, 0.5, 1].map((t) => (
          <g key={t}>
            <line x1={left} x2={width} y1={plotH - t * plotH + 4} y2={plotH - t * plotH + 4} class="ow-grid" />
            <text x={left - 6} y={plotH - t * plotH + 8} class="ow-axis" text-anchor="end">
              {Math.round(t * max)}
            </text>
          </g>
        ))}
        {rows.map((r, i) => {
          const x0 = left + i * slot + (slot - bw * 3 - 4) / 2;
          return (
            <g key={r.key}>
              {SERIES.map((s, j) => {
                const h = (r[s.key] / max) * plotH;
                return <rect key={s.key} x={x0 + j * (bw + 2)} y={plotH - h + 4} width={bw} height={h} rx={2} class={s.cls} />;
              })}
              {(rows.length <= 8 || i % 2 === 0) && (
                <text x={left + i * slot + slot / 2} y={height - 14} class="ow-axis" text-anchor="middle">
                  {formatDateShort(r.key).replace(/^\w+, /, "")}
                </text>
              )}
            </g>
          );
        })}
      </svg>
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
                  <WeekBars rows={d.byWeek} />
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
