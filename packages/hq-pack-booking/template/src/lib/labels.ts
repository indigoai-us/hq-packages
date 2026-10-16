// Plain-language labels. Pure, so node --test runs it.

import type { BookingLocation, LocationOption } from "./types.ts";

const VIDEO: Record<string, string> = { meet: "Google Meet", zoom: "Zoom", teams: "Microsoft Teams" };

export function locationTitle(l: LocationOption | BookingLocation): string {
  switch (l.type) {
    case "meet":
    case "zoom":
    case "teams":
      return VIDEO[l.type] as string;
    case "custom":
      return ("label" in l && l.label) || "Video link from the host";
    case "phone":
      return "Phone call";
    case "in-person":
      return "In person";
    default:
      return l.type;
  }
}

export function locationDetail(l: LocationOption): string {
  switch (l.type) {
    case "meet":
    case "zoom":
    case "teams":
      return "A join link comes with your confirmation.";
    case "custom":
      return "The host's own meeting link comes with your confirmation.";
    case "phone":
      return l.caller === "host" ? "The host calls you. You'll add your number." : "You call the host. The number comes with your confirmation.";
    case "in-person":
      return l.address;
    default:
      return "";
  }
}

export function kindLabel(kind: string, teamSize: number): string | null {
  if (kind === "round-robin") return `With one of ${teamSize} team members`;
  if (kind === "collective") return `With ${teamSize} hosts`;
  if (kind === "group") return "Group session";
  return null;
}

/** "Alex Rivera", "Alex Rivera and Ben Ode", "Alex, Ben and Cy". */
export function nameList(names: string[]): string {
  if (names.length <= 1) return names[0] ?? "";
  if (names.length === 2) return `${names[0]} and ${names[1]}`;
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
}

export function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  return ((parts[0]?.[0] ?? "") + (parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? "") : "")).toUpperCase() || "?";
}

/** "northwind-labs" -> "Northwind Labs". */
export function companyName(slug: string): string {
  return slug
    .split(/[-_]/)
    .filter(Boolean)
    .map((w) => w[0]!.toUpperCase() + w.slice(1))
    .join(" ");
}
