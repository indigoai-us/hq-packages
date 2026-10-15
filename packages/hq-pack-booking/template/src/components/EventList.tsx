import { kindLabel, locationTitle } from "../lib/labels.ts";
import { formatDuration } from "../lib/time.ts";
import { Icon, Link } from "../ui.tsx";
import type { EventListProps } from "./types.ts";

function locationIcon(type: string): string {
  if (type === "phone") return "phone";
  if (type === "in-person") return "pin";
  return "video";
}

/** The company's public event types as a list of links. */
export default function EventList({ eventTypes, hrefFor }: EventListProps) {
  if (!eventTypes.length) return <p class="bk-empty">There are no times to book here right now.</p>;
  return (
    <ul class="bk-event-list" aria-label="Meeting types">
      {eventTypes.map((ev) => {
        const kind = kindLabel(ev.kind, ev.teamSize);
        return (
          <li key={ev.id}>
            <Link href={hrefFor(ev)} class="bk-event-row">
              <span class="bk-event-main">
                <span class="bk-event-title">{ev.title}</span>
                {ev.description && <span class="bk-event-desc">{ev.description}</span>}
                <span class="bk-event-meta">
                  <span>
                    <Icon name="clock" size={14} />
                    {ev.durations.map(formatDuration).join(" or ")}
                  </span>
                  {ev.locations[0] && (
                    <span>
                      <Icon name={locationIcon(ev.locations[0].type)} size={14} />
                      {ev.locations.map(locationTitle).join(", ")}
                    </span>
                  )}
                  {kind && (
                    <span>
                      <Icon name="users" size={14} />
                      {kind}
                    </span>
                  )}
                </span>
              </span>
              <span class="bk-event-go" aria-hidden="true">
                <Icon name="right" size={18} />
              </span>
            </Link>
          </li>
        );
      })}
    </ul>
  );
}
