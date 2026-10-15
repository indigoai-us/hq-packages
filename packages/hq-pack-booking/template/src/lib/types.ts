// Shapes from the booking API (API.md). Only what the pages read.

export type Kind = "one-on-one" | "round-robin" | "collective" | "group";

export interface Question {
  id: string;
  label: string;
  type: "text" | "textarea" | "email" | "phone" | "number" | "select" | "radio" | "checkbox";
  required: boolean;
  options?: string[];
  maxLength?: number;
}

export type LocationOption =
  | { type: "meet" | "zoom" | "teams" }
  | { type: "custom"; label?: string }
  | { type: "phone"; caller: "host" | "invitee" }
  | { type: "in-person"; address: string };

export interface EventType {
  id: string;
  title: string;
  description: string | null;
  kind: Kind;
  durations: number[];
  defaultDuration: number;
  startIncrement: number;
  minimumNotice: number;
  bookingWindow: number;
  seats: number | null;
  guestsMax: number;
  secret: boolean;
  locations: LocationOption[];
  questions: Question[];
  hosts: { name: string }[];
  teamSize: number;
  policy: { cancelCutoffHours: number | null; rescheduleCutoffHours: number | null; requireCancelReason: boolean };
  confirmation: { message?: string; redirectUrl?: string } | null;
  timezone: string;
}

export interface Theme {
  source?: "brand-pack" | "custom";
  brandPack?: string;
  colors?: { primary?: string; background?: string; surface?: string; text?: string; muted?: string; accent?: string };
  fonts?: { heading?: string; body?: string };
  radius?: number;
  logo?: string;
  image?: string;
}

export interface RoutingFormView {
  id: string;
  title: string;
  questions: Question[];
}

export interface PublicConfig {
  company: string;
  timezone: string | null;
  theme: Theme;
  embed: { modes: string[]; allowedOrigins: string[] };
  eventTypes: EventType[];
  routingForms: RoutingFormView[];
  provider: string;
  sandbox: boolean;
}

export interface Slot {
  start: string;
  end: string;
  date: string;
  time: string;
  seatsLeft?: number;
}

export interface Hold {
  holdId: string;
  eventType: string;
  duration: number;
  start: string;
  end: string;
  expiresAt: string;
}

export interface BookingLocation {
  type: string;
  provider?: string;
  joinUrl?: string;
  sandbox?: boolean;
  url?: string;
  label?: string;
  caller?: string;
  phone?: string;
  address?: string;
  text: string;
}

export interface Booking {
  id: string;
  status: "confirmed" | "canceled";
  eventType: { id: string; title: string; kind: Kind };
  start: string;
  end: string;
  duration: number;
  timezone: string;
  location: BookingLocation | null;
  hosts: { name: string; id?: string }[];
  invitee: { name: string; email: string } | null;
  guests: string[];
  answers: Record<string, unknown>;
  bookedBy: string | null;
  cancelReason: string | null;
  rescheduleCount: number;
  policy: { canCancel: boolean; canReschedule: boolean; cancelCutoffHours: number | null; rescheduleCutoffHours: number | null; requireCancelReason: boolean };
  confirmation: { message?: string; redirectUrl?: string } | null;
  sandbox: boolean;
}

export interface BookingResult {
  booking: Booking;
  manageToken: string;
  manageUrl: string;
  icsUrl: string;
  redirectUrl: string | null;
}

export interface OwnerBooking extends Booking {
  hostIds: string[];
  hosts: { id: string; name: string }[];
  createdBy: "invitee" | "owner" | "agent";
  agentKeyId: string | null;
  memberId: string | null;
  agentNote: { text: string; untrusted: true } | null;
  utm: Record<string, string> | null;
  linkId: string | null;
  noShow: boolean;
  calendarStatus: string;
  canceledBy: string | null;
  canceledAt: string | null;
  createdAt: string;
  updatedAt: string;
  inviteeRedacted: boolean;
}

export interface OwnerSession {
  ok: boolean;
  company: string;
  provider: string;
  sandbox: boolean;
  store: string;
  hosts?: { id: string; name: string; timezone: string }[];
  eventTypes?: { id: string; title: string; kind: Kind; secret: boolean; durations: number[] }[];
}
