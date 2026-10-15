// Pure helpers for the owner dashboard: plain labels for internal keys,
// week filling for charts, and side-by-side lanes for overlapping calendar blocks.

import { addDays, weekStart } from "./time.ts";

/** "company_size" or "booking.no-show" -> "Company size" / "Booking no show". */
export function humanizeKey(key: string): string {
  const t = key.replace(/[._-]+/g, " ").trim();
  return t ? `${t.charAt(0).toUpperCase()}${t.slice(1)}` : key;
}

const CALENDAR_STATUS: Record<string, string> = {
  pending: "Waiting to sync",
  created: "On the host's calendar",
  updated: "Updated on the host's calendar",
  canceled: "Removed from the host's calendar",
  failed: "Couldn't add it to the calendar",
  "cancel-failed": "Couldn't remove it from the calendar",
  "update-failed": "Couldn't update the calendar",
};

/** Calendar sync state in plain words. */
export function calendarStatusLabel(status: string): string {
  return CALENDAR_STATUS[status] ?? humanizeKey(status);
}

const AUDIT_ACTIONS: Record<string, string> = {
  "booking.created": "Booked",
  "booking.rescheduled": "Rescheduled",
  "booking.canceled": "Canceled",
  "booking.undone": "Undone",
  "invitee.deleted": "Invitee data deleted",
  "invitee.retention-purge": "Invitee data removed after the retention period",
  "agent.approval-requested": "An agent asked for approval",
  "agent.needs-member-approval": "Sent to the member to approve",
  "agent.offers": "An agent asked for open times",
  "approval.declined": "Approval declined",
  "approval.expired": "Approval expired",
};

/** Audit trail action in plain words. */
export function auditActionLabel(action: string): string {
  return AUDIT_ACTIONS[action] ?? humanizeKey(action);
}

export interface WeekTally {
  key: string;
  bookings: number;
  canceled: number;
  noShows: number;
}

/** Every Monday from `from` up to (not including) `to`, with empty weeks filled in. */
export function fillWeeks(rows: WeekTally[], from: string, to: string): WeekTally[] {
  const byKey = new Map(rows.map((r) => [r.key, r]));
  const out: WeekTally[] = [];
  const end = to.slice(0, 10);
  for (let w = weekStart(from.slice(0, 10)); w < end && out.length < 60; w = addDays(w, 7)) out.push(byKey.get(w) ?? { key: w, bookings: 0, canceled: 0, noShows: 0 });
  for (const r of rows) if (!out.some((o) => o.key === r.key)) out.push(r);
  return out.sort((a, b) => (a.key < b.key ? -1 : 1));
}

export interface Laned {
  day: number;
  top: number;
  height: number;
  lane: number;
  lanes: number;
}

/** Puts overlapping blocks of one day side by side instead of on top of each other. */
export function assignLanes(blocks: Laned[]): void {
  const days = [...new Set(blocks.map((b) => b.day))];
  for (const day of days) {
    const list = blocks.filter((b) => b.day === day).sort((a, b) => a.top - b.top || b.height - a.height);
    let group: Laned[] = [];
    let groupEnd = -Infinity;
    const close = () => {
      const n = group.reduce((m, b) => Math.max(m, b.lane + 1), 0);
      for (const b of group) b.lanes = n;
      group = [];
    };
    for (const b of list) {
      if (b.top >= groupEnd) close();
      const laneEnds: number[] = [];
      for (const g of group) laneEnds[g.lane] = Math.max(laneEnds[g.lane] ?? -Infinity, g.top + g.height);
      let lane = 0;
      while (laneEnds[lane] !== undefined && (laneEnds[lane] as number) > b.top) lane++;
      b.lane = lane;
      group.push(b);
      groupEnd = Math.max(groupEnd, b.top + b.height);
    }
    close();
  }
}
