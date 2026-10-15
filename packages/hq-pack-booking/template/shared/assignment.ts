// Round-robin host choice. Among the hosts free for a slot, prefer higher
// priority, then the host furthest below their weighted share of bookings,
// then the host booked least recently, then host id. The same inputs always
// give the same host.

import type { ExistingBooking } from "./availability.ts";

export interface HostStats {
  id: string;
  weight: number;
  priority: number;
  bookings: number;
  lastBookedAt: number | null;
}

export interface RoundRobinHost {
  id: string;
  roundRobin?: { weight?: number; priority?: number };
}

export function statsFor(eventTypeId: string, hosts: RoundRobinHost[], bookings: ExistingBooking[]): HostStats[] {
  return hosts.map((h) => {
    const mine = bookings.filter((b) => b.eventTypeId === eventTypeId && b.hostIds.includes(h.id));
    return {
      id: h.id,
      weight: h.roundRobin?.weight ?? 1,
      priority: h.roundRobin?.priority ?? 0,
      bookings: mine.length,
      lastBookedAt: mine.length ? Math.max(...mine.map((b) => b.start)) : null,
    };
  });
}

export function pickHost(freeHostIds: string[], stats: HostStats[]): string {
  if (freeHostIds.length === 0) throw new Error("no free host to assign");
  const byId = new Map(stats.map((s) => [s.id, s]));
  const candidates = freeHostIds.map((id) => byId.get(id) ?? { id, weight: 1, priority: 0, bookings: 0, lastBookedAt: null });
  candidates.sort((a, b) => {
    if (a.priority !== b.priority) return b.priority - a.priority;
    const loadA = a.bookings / a.weight;
    const loadB = b.bookings / b.weight;
    if (loadA !== loadB) return loadA - loadB;
    const lastA = a.lastBookedAt ?? -Infinity;
    const lastB = b.lastBookedAt ?? -Infinity;
    if (lastA !== lastB) return lastA - lastB;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  return (candidates[0] as HostStats).id;
}
