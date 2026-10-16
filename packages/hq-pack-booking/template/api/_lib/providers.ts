// What the booking app needs from the outside world. The prototype ships
// sandbox implementations (sandbox.ts) that keep everything in the app
// database; hqpro.ts implements the same interfaces against the hq-pro
// booking route described in knowledge/booking/hq-pro-contract.md.

export interface BusyBlock {
  start: number;
  end: number;
}

/** A host as providers see them: id, email, zone and calendar choices. Never event details. */
export interface CalendarHost {
  id: string;
  email: string;
  timezone: string;
  calendars?: unknown;
}

export type ConferenceKind = "meet" | "zoom" | "teams";

export interface Conference {
  provider: string;
  joinUrl: string;
  sandbox: boolean;
}

export interface CalendarEventInput {
  host: CalendarHost;
  bookingId: string;
  start: number;
  end: number;
  summary: string;
  description: string;
  location?: string;
  attendees: { name?: string; email: string }[];
  /** Ask the calendar to create the video link (Meet through conferenceData). */
  conference?: ConferenceKind;
  idempotencyKey: string;
}

export interface CalendarProvider {
  readonly name: "sandbox" | "hqpro";
  /** Merged busy blocks per host id. Titles, attendees and descriptions never come back. */
  freeBusy(hosts: CalendarHost[], range: { from: number; to: number }, options?: { ignoreEventIds?: string[] }): Promise<Record<string, BusyBlock[]>>;
  createEvent(input: CalendarEventInput): Promise<{ eventId: string; conference?: Conference }>;
  /** Only events this app created can be changed. */
  updateEvent(eventId: string, input: CalendarEventInput): Promise<void>;
  cancelEvent(eventId: string, host: CalendarHost): Promise<void>;
}

export interface MeetingInput {
  kind: ConferenceKind;
  bookingId: string;
  host: CalendarHost;
  start: number;
  end: number;
  title: string;
}

export interface VideoProvider {
  readonly name: string;
  createMeeting(input: MeetingInput): Promise<Conference>;
}

export interface EmailMessage {
  /** Idempotency key: the same id is never sent twice. */
  id: string;
  kind: string;
  to: string[];
  subject: string;
  html: string;
  text: string;
  bookingId?: string;
  /** Host whose mailbox sends it (hq-pro sends from the host's Gmail). */
  fromHostId?: string;
}

export interface Mailer {
  readonly name: string;
  /** Returns false when this id was already sent. */
  send(message: EmailMessage): Promise<boolean>;
}

export interface DirectMessage {
  id: string;
  recipient: { type: "host" | "member" | "owner"; id: string };
  kind: string;
  title: string;
  body: string;
  data?: Record<string, unknown>;
  bookingId?: string;
  approvalId?: string;
}

export interface Notifier {
  readonly name: string;
  send(message: DirectMessage): Promise<boolean>;
}

export interface Providers {
  calendar: CalendarProvider;
  video: VideoProvider;
  mailer: Mailer;
  notifier: Notifier;
}
