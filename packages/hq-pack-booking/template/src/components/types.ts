// Props each overridable component receives. OVERRIDES.md documents these;
// an override must accept the same props and export the component as default.

import type { Prefill } from "../lib/params.ts";
import type { BookingResult, EventType, LocationOption, PublicConfig, RoutingFormView, Slot } from "../lib/types.ts";

export interface HeaderProps {
  config: PublicConfig;
  /** Set on event, manage and routing pages. */
  eventType?: EventType | null;
}

export interface EventListProps {
  eventTypes: EventType[];
  /** Link for an event type, with the visitor's prefill and utm params carried over. */
  hrefFor: (ev: EventType) => string;
}

export interface DurationPickerProps {
  durations: number[];
  value: number;
  onChange: (minutes: number) => void;
}

export interface SlotPickerProps {
  eventType: EventType;
  duration: number;
  /** Visitor's zone; times are listed in it. */
  timezone: string;
  onTimezoneChange: (tz: string) => void;
  hour12: boolean;
  onHour12Change: (v: boolean) => void;
  /** Round-robin host subset from a routing form. */
  hosts?: string[];
  /** Called when the visitor picks a time. */
  onSelect: (slot: Slot) => void;
  /** Start of the slot being held right now (shown as busy). */
  pending?: string | null;
  /** A plain message to show above the times (for example "Someone just took that time"). */
  message?: string | null;
  /** Start time to leave out (the booking's current time when rescheduling). */
  exclude?: string | null;
  /** Changes when the times should be fetched again. */
  refreshKey?: number;
  /** First date to show, YYYY-MM-DD, from the date URL parameter. */
  initialDate?: string | null;
}

export interface LocationPickerProps {
  locations: LocationOption[];
  /** Index into locations. */
  value: number;
  onChange: (index: number) => void;
  /** Invitee phone number when a phone location has the host call. */
  phone: string;
  onPhoneChange: (v: string) => void;
  error?: string | null;
}

export interface IntakeValues {
  name: string;
  email: string;
  /** Free text; split into emails on submit. */
  guests: string;
  answers: Record<string, string | string[]>;
}

export interface IntakeFormProps {
  eventType: EventType;
  values: IntakeValues;
  onChange: (values: IntakeValues) => void;
  /** Field errors keyed by "name", "email", "guests" or a question id. */
  errors: Record<string, string>;
  disabled?: boolean;
  /** Values that came from URL parameters (shown as filled in). */
  prefill?: Prefill;
}

export interface ConfirmationProps {
  result: BookingResult;
  eventType: EventType;
  timezone: string;
  hour12: boolean;
  embedded: boolean;
}

export interface RoutingFormProps {
  form: RoutingFormView;
  onSubmit: (answers: Record<string, unknown>) => void;
  busy?: boolean;
  error?: string | null;
  initial?: Record<string, string | string[]>;
}

export interface FooterProps {
  config: PublicConfig;
}
