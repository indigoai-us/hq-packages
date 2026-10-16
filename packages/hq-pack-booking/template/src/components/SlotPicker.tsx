import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { api, qs } from "../lib/api.ts";
import { useAsync } from "../lib/hooks.ts";
import type { Slot } from "../lib/types.ts";
import { addDays, addMonths, formatClock, formatDateLong, formatDateShort, monthGrid, monthTitle, wall, zonedInstant, zoneLabel, zoneList } from "../lib/time.ts";
import { ErrorState, Icon, Segmented } from "../ui.tsx";
import type { SlotPickerProps } from "./types.ts";

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const DAY_MS = 86_400_000;

/** Month calendar with open days, the day's times, the time zone and 12/24 hour choice. */
export default function SlotPicker(props: SlotPickerProps) {
  const { eventType, duration, timezone, hour12, hosts, onSelect, pending, message, exclude, refreshKey = 0 } = props;
  const today = wall(Date.now(), timezone).date;
  const lastDay = wall(Date.now() + eventType.bookingWindow * DAY_MS, timezone).date;
  const startDate = props.initialDate && props.initialDate >= today && props.initialDate <= lastDay ? props.initialDate : today;
  const [month, setMonth] = useState(() => ({ year: Number(startDate.slice(0, 4)), month: Number(startDate.slice(5, 7)) }));
  const [selected, setSelected] = useState<string | null>(props.initialDate ?? null);
  const autoAdvanced = useRef(0);
  const gridRef = useRef<HTMLDivElement>(null);

  const monthStart = `${month.year}-${String(month.month).padStart(2, "0")}-01`;
  const next = addMonths(month.year, month.month, 1);
  const nextStart = `${next.year}-${String(next.month).padStart(2, "0")}-01`;
  const canPrev = monthStart > today;
  const canNext = nextStart <= lastDay;

  const slots = useAsync<Slot[]>(
    async (signal) => {
      const now = Date.now();
      const from = Math.max(zonedInstant(monthStart, "00:00", timezone), now);
      const to = Math.min(zonedInstant(nextStart, "00:00", timezone), now + (eventType.bookingWindow + 1) * DAY_MS);
      if (to <= from) return [];
      const r = await api<{ slots: Slot[] }>(
        `/api/slots${qs({ eventType: eventType.id, duration, from: new Date(from).toISOString(), to: new Date(to).toISOString(), tz: timezone, hosts: hosts?.join(",") })}`,
        { signal },
      );
      return r.slots;
    },
    [eventType.id, duration, timezone, monthStart, hosts?.join(","), refreshKey],
  );

  const byDate = useMemo(() => {
    const m = new Map<string, Slot[]>();
    for (const s of slots.data ?? []) {
      if (exclude && s.start === exclude) continue;
      const list = m.get(s.date) ?? [];
      list.push(s);
      m.set(s.date, list);
    }
    return m;
  }, [slots.data, exclude]);

  // Pick the first open day; move to the next month once or twice when this one is empty.
  useEffect(() => {
    if (slots.loading || slots.error || !slots.data) return;
    if (byDate.size === 0) {
      if (canNext && autoAdvanced.current < 2) {
        autoAdvanced.current += 1;
        setMonth(next);
      }
      return;
    }
    autoAdvanced.current = 2;
    if (!selected || !byDate.has(selected)) setSelected([...byDate.keys()].sort()[0] ?? null);
  }, [byDate, slots.loading]);

  const weeks = monthGrid(month.year, month.month);
  const daySlots = selected ? (byDate.get(selected) ?? []) : [];
  const zones = useMemo(() => zoneList([timezone, eventType.timezone]), [timezone, eventType.timezone]);

  const moveFocus = (from: string, delta: number) => {
    let d = from;
    for (let i = 0; i < 62; i++) {
      d = addDays(d, delta);
      if (d < today || d > lastDay) return;
      if (byDate.has(d)) {
        if (d.slice(0, 7) !== monthStart.slice(0, 7)) setMonth({ year: Number(d.slice(0, 4)), month: Number(d.slice(5, 7)) });
        setSelected(d);
        requestAnimationFrame(() => gridRef.current?.querySelector<HTMLButtonElement>(`[data-date="${d}"]`)?.focus());
        return;
      }
    }
  };

  const onDayKey = (e: KeyboardEvent, date: string) => {
    const deltas: Record<string, number> = { ArrowRight: 1, ArrowLeft: -1, ArrowDown: 7, ArrowUp: -7 };
    const delta = deltas[e.key];
    if (delta === undefined) return;
    e.preventDefault();
    moveFocus(date, delta);
  };

  const loadingMonth = slots.loading && !slots.data;
  const listId = "bk-times";

  return (
    <div class="bk-slotpicker">
      <div class="bk-cal">
        <div class="bk-cal-head">
          <h3 class="bk-cal-title" aria-live="polite">
            {monthTitle(month.year, month.month)}
          </h3>
          <div class="bk-cal-nav">
            <button type="button" class="bk-icon-btn" onClick={() => setMonth(addMonths(month.year, month.month, -1))} disabled={!canPrev} aria-label="Previous month">
              <Icon name="left" size={18} />
            </button>
            <button type="button" class="bk-icon-btn" onClick={() => setMonth(next)} disabled={!canNext} aria-label="Next month">
              <Icon name="right" size={18} />
            </button>
          </div>
        </div>
        <div class="bk-cal-grid" ref={gridRef} role="group" aria-label={`Days in ${monthTitle(month.year, month.month)}`} aria-busy={slots.loading ? "true" : undefined}>
          {WEEKDAYS.map((d) => (
            <span key={d} class="bk-cal-wd" aria-hidden="true">
              {d}
            </span>
          ))}
          {weeks.flat().map((cell) => {
            if (!cell.inMonth) return <span key={cell.date} class="bk-cal-pad" aria-hidden="true" />;
            const open = byDate.get(cell.date);
            const isSel = cell.date === selected;
            const label = `${formatDateLong(cell.date)}${open ? `, ${open.length} time${open.length === 1 ? "" : "s"} open` : ", no open times"}`;
            return (
              <button
                key={cell.date}
                type="button"
                data-date={cell.date}
                class={`bk-day${open ? " is-open" : ""}${isSel ? " is-selected" : ""}${cell.date === today ? " is-today" : ""}`}
                disabled={!open}
                aria-pressed={isSel}
                aria-label={label}
                aria-controls={listId}
                onClick={() => setSelected(cell.date)}
                onKeyDown={(e) => onDayKey(e as unknown as KeyboardEvent, cell.date)}
              >
                {cell.day}
              </button>
            );
          })}
        </div>
        {slots.error && <ErrorState message={slots.error} onRetry={slots.reload} />}
        {!slots.loading && !slots.error && byDate.size === 0 && (
          <p class="bk-cal-empty">
            No open times in {monthTitle(month.year, month.month)}.{" "}
            {canNext && (
              <button type="button" class="bk-textlink" onClick={() => setMonth(next)}>
                Check next month
              </button>
            )}
          </p>
        )}
        <div class="bk-zone-row">
          <label class="bk-zone">
            <Icon name="globe" size={15} />
            <span class="bk-sr">Time zone</span>
            <select value={timezone} onChange={(e) => props.onTimezoneChange((e.currentTarget as HTMLSelectElement).value)}>
              {zones.map((z) => (
                <option key={z} value={z}>
                  {zoneLabel(z)}
                </option>
              ))}
            </select>
          </label>
          <Segmented
            label="Clock format"
            value={hour12 ? "12" : "24"}
            options={[
              { value: "12", label: "12h" },
              { value: "24", label: "24h" },
            ]}
            onChange={(v) => props.onHour12Change(v === "12")}
          />
        </div>
      </div>

      <div class="bk-times" id={listId} aria-live="polite" aria-busy={slots.loading ? "true" : undefined}>
        <h3 class="bk-times-title">{selected ? formatDateShort(selected) : "Pick a day"}</h3>
        {message && (
          <p class="bk-times-message" role="alert">
            {message}
          </p>
        )}
        <div class="bk-times-list">
          {loadingMonth ? (
            <>
              <span class="bk-sr" role="status">
                Loading open times
              </span>
              {[0, 1, 2, 3, 4, 5].map((i) => (
                <span key={i} class="bk-slot bk-slot-skeleton" aria-hidden="true" />
              ))}
            </>
          ) : (
            daySlots.map((s) => (
              <button
                key={s.start}
                type="button"
                class={`bk-slot${pending === s.start ? " is-pending" : ""}`}
                onClick={() => onSelect(s)}
                disabled={!!pending}
                aria-label={`${formatClock(s.time, hour12)}, ${selected ? formatDateLong(selected) : ""}${s.seatsLeft !== undefined ? `, ${s.seatsLeft} seats left` : ""}`}
              >
                <span>{formatClock(s.time, hour12)}</span>
                {pending === s.start ? <span class="bk-slot-note">Holding…</span> : s.seatsLeft !== undefined ? <span class="bk-slot-note">{s.seatsLeft} left</span> : null}
              </button>
            ))
          )}
          {!loadingMonth && selected && !daySlots.length && !slots.error && <p class="bk-empty">No open times on this day.</p>}
        </div>
      </div>
    </div>
  );
}
