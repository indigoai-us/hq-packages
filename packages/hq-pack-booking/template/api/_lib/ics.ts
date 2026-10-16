// iCalendar (RFC 5545) file for one booking.

export interface IcsInput {
  uid: string;
  sequence: number;
  start: number;
  end: number;
  stamp: number;
  summary: string;
  description: string;
  location: string;
  url?: string;
  canceled: boolean;
  organizer?: { name: string; email: string };
}

function stamp(ms: number): string {
  return new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

export function escapeIcs(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

/** Fold lines longer than 75 octets, as RFC 5545 requires. */
function fold(line: string): string {
  const out: string[] = [];
  let rest = line;
  while (Buffer.byteLength(rest, "utf8") > 75) {
    let cut = 75;
    while (Buffer.byteLength(rest.slice(0, cut), "utf8") > 75) cut--;
    out.push(rest.slice(0, cut));
    rest = ` ${rest.slice(cut)}`;
  }
  out.push(rest);
  return out.join("\r\n");
}

export function buildIcs(e: IcsInput): string {
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//HQ Booking//EN",
    "CALSCALE:GREGORIAN",
    `METHOD:${e.canceled ? "CANCEL" : "PUBLISH"}`,
    "BEGIN:VEVENT",
    `UID:${escapeIcs(e.uid)}`,
    `SEQUENCE:${e.sequence}`,
    `DTSTAMP:${stamp(e.stamp)}`,
    `DTSTART:${stamp(e.start)}`,
    `DTEND:${stamp(e.end)}`,
    `SUMMARY:${escapeIcs(e.summary)}`,
    `DESCRIPTION:${escapeIcs(e.description)}`,
    `LOCATION:${escapeIcs(e.location)}`,
    ...(e.url ? [`URL:${escapeIcs(e.url)}`] : []),
    ...(e.organizer ? [`ORGANIZER;CN=${escapeIcs(e.organizer.name)}:mailto:${e.organizer.email}`] : []),
    `STATUS:${e.canceled ? "CANCELLED" : "CONFIRMED"}`,
    "END:VEVENT",
    "END:VCALENDAR",
  ];
  return `${lines.map(fold).join("\r\n")}\r\n`;
}
