// The one place the API reaches into ../../shared. hq-deploy uploads only
// api/, dist/ and db/migrations/, so dev/stage.ts copies the shared engine
// into api/_lib/shared/ and rewrites the two paths below to ./shared/.
// Only modules with no npm dependencies are imported at run time; config.ts
// (which needs the yaml package) is used for types only.

export { computeSlots, SlotQueryError } from "../../shared/availability.ts";
export type { ExistingBooking, HostInput, Interval, Slot } from "../../shared/availability.ts";
export { pickHost } from "../../shared/assignment.ts";
export type { HostStats } from "../../shared/assignment.ts";
export { isValidTimeZone, parseRange, wallParts, wallToInstant, WEEKDAYS } from "../../shared/time.ts";
export type {
  AgentBookingRules,
  BookingConfig,
  EventType,
  Host,
  Location,
  Notifications,
  Question,
  RoutingForm,
  RoutingTarget,
} from "../../shared/config.ts";
