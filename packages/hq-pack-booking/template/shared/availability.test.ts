import { test } from "node:test";
import assert from "node:assert/strict";
import { computeSlots, SlotQueryError, type ExistingBooking, type HostInput, type SlotQuery } from "./availability.ts";
import { pickHost, statsFor } from "./assignment.ts";
import { addDays, MINUTE, offsetMinutes, parseDate, wallParts, wallToInstant, weekdayOf } from "./time.ts";

const iso = (s: string) => Date.parse(s);
const WEEKDAYS_9_TO_5 = { mon: ["09:00-17:00"], tue: ["09:00-17:00"], wed: ["09:00-17:00"], thu: ["09:00-17:00"], fri: ["09:00-17:00"] };

function host(id: string, timezone: string, extra: Partial<HostInput> = {}): HostInput {
  return { id, timezone, hours: WEEKDAYS_9_TO_5, busy: [], ...extra };
}

function query(extra: Omit<Partial<SlotQuery>, "eventType"> & { eventType?: Partial<SlotQuery["eventType"]> } = {}): SlotQuery {
  const { eventType, ...rest } = extra;
  return {
    eventType: { id: "intro", kind: "one-on-one", hosts: ["ana"], durations: [30], startIncrement: 30, ...eventType },
    duration: 30,
    hosts: [host("ana", "America/New_York")],
    bookings: [],
    now: iso("2026-11-02T00:00:00Z"), // Monday
    from: iso("2026-11-02T00:00:00Z"),
    to: iso("2026-11-03T00:00:00Z"),
    ...rest,
  };
}

const starts = (q: SlotQuery) => computeSlots(q).map((s) => new Date(s.start).toISOString());

test("time helpers", () => {
  assert.equal(addDays("2026-02-28", 1), "2026-03-01");
  assert.equal(addDays("2028-02-28", 1), "2028-02-29");
  assert.equal(weekdayOf("2026-11-02"), "mon");
  assert.equal(parseDate("2026-02-29"), null);
  assert.equal(parseDate("nope"), null);
  assert.throws(() => addDays("x", 1), /bad date/);
  assert.throws(() => weekdayOf("x"), /bad date/);
  assert.throws(() => wallToInstant("x", 0, "UTC"), /bad date/);
  assert.equal(offsetMinutes(iso("2026-07-01T12:00:00Z"), "America/New_York"), -240);
  assert.equal(offsetMinutes(iso("2026-01-01T12:00:00Z"), "Asia/Kolkata"), 330);
  assert.deepEqual(wallParts(iso("2026-11-02T14:30:00Z"), "America/New_York"), { date: "2026-11-02", minutes: 9 * 60 + 30, weekday: "mon" });
  // 02:30 on 2026-03-08 does not exist in New York; 01:30 on 2026-11-01 happens twice.
  assert.equal(wallToInstant("2026-03-08", 150, "America/New_York"), null);
  assert.equal(wallToInstant("2026-11-01", 90, "America/New_York"), iso("2026-11-01T05:30:00Z"));
  assert.equal(wallToInstant("2026-11-02", 1440, "America/New_York"), iso("2026-11-03T05:00:00Z"));
});

test("one-on-one: working hours in the host's zone, every increment", () => {
  const s = starts(query());
  assert.equal(s.length, 16); // 09:00..16:30 every 30 min
  assert.equal(s[0], "2026-11-02T14:00:00.000Z"); // 09:00 EST
  assert.equal(s.at(-1), "2026-11-02T21:30:00.000Z"); // 16:30 EST
});

test("busy blocks and buffers remove overlapping starts", () => {
  const busy = [{ start: iso("2026-11-02T15:00:00Z"), end: iso("2026-11-02T16:00:00Z") }]; // 10-11 EST
  const plain = starts(query({ hosts: [host("ana", "America/New_York", { busy })] }));
  assert.ok(!plain.includes("2026-11-02T15:00:00.000Z"));
  assert.ok(!plain.includes("2026-11-02T15:30:00.000Z"));
  assert.ok(plain.includes("2026-11-02T14:30:00.000Z"));
  assert.ok(plain.includes("2026-11-02T16:00:00.000Z"));
  const buffered = starts(query({ eventType: { buffers: { before: 15, after: 15 } }, hosts: [host("ana", "America/New_York", { busy })] }));
  assert.ok(!buffered.includes("2026-11-02T14:30:00.000Z")); // ends 10:00, +15 after overlaps
  assert.ok(!buffered.includes("2026-11-02T16:00:00.000Z")); // starts 11:00, -15 before overlaps
  assert.ok(buffered.includes("2026-11-02T14:00:00.000Z"));
});

test("existing bookings block the host like calendar events", () => {
  const bookings: ExistingBooking[] = [{ eventTypeId: "other", hostIds: ["ana"], start: iso("2026-11-02T14:00:00Z"), end: iso("2026-11-02T14:30:00Z") }];
  assert.ok(!starts(query({ bookings })).includes("2026-11-02T14:00:00.000Z"));
});

test("minimum notice, booking window and the requested range", () => {
  const now = iso("2026-11-02T17:10:00Z"); // 12:10 EST
  const s = starts(query({ now, eventType: { minimumNotice: 60 } }));
  assert.equal(s[0], "2026-11-02T18:30:00.000Z"); // first start at or after 13:10 on the half hour
  const windowed = computeSlots(query({ now: iso("2026-11-02T00:00:00Z"), from: undefined, to: undefined, eventType: { bookingWindow: 3 } }));
  assert.ok(windowed.every((x) => x.start < iso("2026-11-05T00:00:00Z")));
  assert.equal(computeSlots(query({ from: iso("2026-11-03T00:00:00Z"), to: iso("2026-11-02T00:00:00Z") })).length, 0);
});

test("default increment and window when not set", () => {
  const q = query({ from: undefined, to: undefined });
  delete q.eventType.startIncrement;
  const s = computeSlots(q);
  assert.equal(s[1]!.start - s[0]!.start, 15 * MINUTE);
  assert.ok(s.at(-1)!.start < q.now + 60 * 86_400_000);
  assert.ok(s.at(-1)!.start > q.now + 55 * 86_400_000);
});

test("overrides replace the day, holidays remove it, weekends are closed", () => {
  const h = host("ana", "America/New_York", { overrides: [{ date: "2026-11-02", hours: ["10:00-11:00"] }], holidays: ["2026-11-03"] });
  const range = { from: iso("2026-11-02T00:00:00Z"), to: iso("2026-11-09T00:00:00Z") };
  const s = computeSlots(query({ hosts: [h], ...range }));
  const days = new Set(s.map((x) => wallParts(x.start, "America/New_York").date));
  assert.ok(!days.has("2026-11-03"));
  assert.ok(!days.has("2026-11-07") && !days.has("2026-11-08"));
  assert.deepEqual(s.filter((x) => wallParts(x.start, "America/New_York").date === "2026-11-02").map((x) => wallParts(x.start, "America/New_York").minutes), [600, 630]);
  const closed = host("ana", "America/New_York", { overrides: [{ date: "2026-11-02", hours: [] }] });
  assert.equal(computeSlots(query({ hosts: [closed] })).length, 0);
});

test("daily limit per host per local day", () => {
  const bookings: ExistingBooking[] = [
    { eventTypeId: "intro", hostIds: ["ana"], start: iso("2026-11-03T14:00:00Z"), end: iso("2026-11-03T14:30:00Z") },
    { eventTypeId: "intro", hostIds: ["ana"], start: iso("2026-11-03T15:00:00Z"), end: iso("2026-11-03T15:30:00Z") },
    { eventTypeId: "other", hostIds: ["ana"], start: iso("2026-11-02T20:00:00Z"), end: iso("2026-11-02T20:30:00Z") },
  ];
  const s = computeSlots(query({ eventType: { dailyLimit: 2 }, bookings, to: iso("2026-11-05T00:00:00Z") }));
  const days = new Set(s.map((x) => wallParts(x.start, "America/New_York").date));
  assert.ok(days.has("2026-11-02"));
  assert.ok(!days.has("2026-11-03"));
  assert.ok(days.has("2026-11-04"));
});

test("DST: New York host, London visitor, March change: no slot outside the host's hours", () => {
  // US clocks change 2026-03-08, UK clocks 2026-03-29. In between, the gap is 4 hours, not 5.
  const q = query({
    hosts: [host("ana", "America/New_York")],
    from: iso("2026-03-02T00:00:00Z"),
    to: iso("2026-04-04T00:00:00Z"),
    now: iso("2026-03-01T00:00:00Z"),
  });
  const s = computeSlots(q);
  assert.ok(s.length > 0);
  for (const slot of s) {
    const start = wallParts(slot.start, "America/New_York");
    const end = wallParts(slot.end, "America/New_York");
    assert.ok(start.minutes >= 9 * 60 && end.minutes <= 17 * 60, `${new Date(slot.start).toISOString()} is outside 09:00-17:00 New York`);
    assert.ok(!["sat", "sun"].includes(start.weekday));
  }
  const london = (d: string) =>
    s.filter((x) => wallParts(x.start, "America/New_York").date === d).map((x) => wallParts(x.start, "Europe/London").minutes)[0];
  assert.equal(london("2026-03-06"), 14 * 60); // before US change: 09:00 NY = 14:00 London
  assert.equal(london("2026-03-09"), 13 * 60); // between changes: 09:00 NY = 13:00 London
  assert.equal(london("2026-03-30"), 14 * 60); // after UK change: back to 14:00
});

test("DST: ranges that touch a skipped hour keep their real length", () => {
  const night = host("ana", "America/New_York", { hours: { sun: ["01:00-04:00"] } });
  const s = computeSlots(query({
    hosts: [night],
    eventType: { durations: [60], startIncrement: 60 },
    duration: 60,
    from: iso("2026-03-08T00:00:00Z"),
    to: iso("2026-03-09T00:00:00Z"),
    now: iso("2026-03-07T00:00:00Z"),
  }));
  // 01:00 EST and 03:00 EDT exist; 02:00 does not. 01:00 to 04:00 is two real hours.
  assert.deepEqual(s.map((x) => new Date(x.start).toISOString()), ["2026-03-08T06:00:00.000Z", "2026-03-08T07:00:00.000Z"]);
  const gapStart = host("ana", "America/New_York", { hours: { sun: ["02:30-05:00"] } });
  const g = computeSlots(query({ hosts: [gapStart], eventType: { durations: [60], startIncrement: 30 }, duration: 60, from: iso("2026-03-08T00:00:00Z"), to: iso("2026-03-09T00:00:00Z"), now: iso("2026-03-07T00:00:00Z") }));
  assert.equal(new Date(g[0]!.start).toISOString(), "2026-03-08T07:00:00.000Z"); // 03:00 EDT
});

test("round-robin: a slot is open when any host is free", () => {
  const hosts = [host("ana", "America/New_York"), host("ben", "America/Los_Angeles")];
  const s = computeSlots(query({ eventType: { kind: "round-robin", hosts: ["ana", "ben"] }, hosts }));
  const first = s[0]!;
  assert.deepEqual(first.hostIds, ["ana"]); // 09:00 NY, ben not yet working
  const late = s.find((x) => new Date(x.start).toISOString() === "2026-11-02T23:30:00.000Z")!; // 15:30 LA
  assert.deepEqual(late.hostIds, ["ben"]);
  const both = s.find((x) => new Date(x.start).toISOString() === "2026-11-02T17:00:00.000Z")!; // 12:00 NY, 09:00 LA
  assert.deepEqual(both.hostIds, ["ana", "ben"]);
});

test("round-robin: two hosts, four sequential bookings, each gets two", () => {
  const hosts = [host("ana", "America/New_York"), host("ben", "America/New_York")];
  const config = [{ id: "ana" }, { id: "ben" }];
  const bookings: ExistingBooking[] = [];
  for (let i = 0; i < 4; i++) {
    const s = computeSlots(query({ eventType: { kind: "round-robin", hosts: ["ana", "ben"] }, hosts, bookings }));
    const slot = s[0]!;
    const chosen = pickHost(slot.hostIds, statsFor("rr", config, bookings.map((b) => ({ ...b, eventTypeId: "rr" }))));
    bookings.push({ eventTypeId: "intro", hostIds: [chosen], start: slot.start, end: slot.end });
  }
  const counts = { ana: 0, ben: 0 } as Record<string, number>;
  for (const b of bookings) counts[b.hostIds[0]!]! += 1;
  assert.deepEqual(counts, { ana: 2, ben: 2 });
});

test("round-robin assignment: priority, weight, recency, id; deterministic", () => {
  const hosts = [
    { id: "ana", roundRobin: { weight: 2 } },
    { id: "ben" },
    { id: "cat", roundRobin: { priority: 1 } },
  ];
  const b = (id: string, at: string): ExistingBooking => ({ eventTypeId: "rr", hostIds: [id], start: iso(at), end: iso(at) + 30 * MINUTE });
  assert.equal(pickHost(["ana", "ben", "cat"], statsFor("rr", hosts, [])), "cat");
  // ana has weight 2, so two bookings put her level with ben's one.
  const twoForAna = [b("ana", "2026-11-02T14:00:00Z"), b("ana", "2026-11-02T15:00:00Z"), b("ben", "2026-11-02T13:00:00Z")];
  assert.equal(pickHost(["ana", "ben"], statsFor("rr", hosts, twoForAna)), "ben"); // equal load, ben booked less recently
  assert.equal(pickHost(["ana", "ben"], statsFor("rr", hosts, [b("ben", "2026-11-02T13:00:00Z")])), "ana");
  assert.equal(pickHost(["ben", "ana"], statsFor("rr", [{ id: "ana" }, { id: "ben" }], [])), "ana");
  assert.equal(pickHost(["zed"], []), "zed");
  assert.throws(() => pickHost([], []), /no free host/);
  const s1 = statsFor("rr", hosts, twoForAna);
  assert.equal(pickHost(["ana", "ben"], s1), pickHost(["ben", "ana"], s1));
});

test("collective: only times when every host is free", () => {
  const hosts = [
    host("ana", "America/New_York"),
    host("ben", "America/New_York", { busy: [{ start: iso("2026-11-02T14:00:00Z"), end: iso("2026-11-02T20:00:00Z") }] }),
  ];
  const s = computeSlots(query({ eventType: { kind: "collective", hosts: ["ana", "ben"] }, hosts }));
  assert.ok(s.length > 0);
  for (const slot of s) {
    assert.ok(slot.start >= iso("2026-11-02T20:00:00Z"));
    assert.deepEqual(slot.hostIds, ["ana", "ben"]);
  }
});

test("group: a slot stays open until the seats are filled", () => {
  const ev = { id: "class", kind: "group" as const, hosts: ["ana"], durations: [60], startIncrement: 60, seats: 3 };
  const at = iso("2026-11-02T14:00:00Z");
  const booked = (n: number): ExistingBooking[] => Array.from({ length: n }, () => ({ eventTypeId: "class", hostIds: ["ana"], start: at, end: at + 60 * MINUTE }));
  // The group's own calendar event must not block its other seats.
  const busy = [{ start: at, end: at + 60 * MINUTE }];
  const run = (bookings: ExistingBooking[]) =>
    computeSlots(query({ eventType: ev, duration: 60, hosts: [host("ana", "America/New_York", { busy })], bookings })).find((s) => s.start === at);
  assert.equal(run([]), undefined); // with no seats booked, the busy block is someone else's meeting
  assert.equal(run(booked(1))?.seatsLeft, 2);
  assert.equal(run(booked(2))?.seatsLeft, 1);
  assert.equal(run(booked(3)), undefined);
  const multiSeat: ExistingBooking[] = [{ eventTypeId: "class", hostIds: ["ana"], start: at, end: at + 60 * MINUTE, seats: 2 }];
  assert.equal(run(multiSeat)?.seatsLeft, 1);
  const free = computeSlots(query({ eventType: ev, duration: 60 })).find((s) => s.start === at);
  assert.equal(free?.seatsLeft, 3);
});

test("bad queries are refused", () => {
  assert.throws(() => computeSlots(query({ duration: 45 })), SlotQueryError);
  assert.throws(() => computeSlots(query({ hosts: [] })), /no availability input for host ana/);
});
