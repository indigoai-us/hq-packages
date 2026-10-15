import { locationTitle, nameList } from "../lib/labels.ts";
import { formatRange, zoneLabel } from "../lib/time.ts";
import { Icon, Link, SandboxNote } from "../ui.tsx";
import type { ConfirmationProps } from "./types.ts";

/** The booked screen: time, place, people, calendar file and manage link. */
export default function Confirmation({ result, eventType, timezone, hour12, embedded }: ConfirmationProps) {
  const b = result.booking;
  const loc = b.location;
  const join = loc?.joinUrl ?? loc?.url;
  const hosts = b.hosts.map((h) => h.name);
  const message = b.confirmation?.message ?? eventType.confirmation?.message;
  return (
    <section class="bk-confirm" aria-labelledby="bk-confirm-title">
      <span class="bk-confirm-mark" aria-hidden="true">
        <Icon name="check" size={22} />
      </span>
      <h1 id="bk-confirm-title" class="bk-confirm-title" tabIndex={-1}>
        You're booked
      </h1>
      <p class="bk-confirm-lede">
        {b.invitee ? (
          <>
            A calendar invitation is on its way to <span class="bk-strong">{b.invitee.email}</span>.
          </>
        ) : (
          "A calendar invitation is on its way."
        )}
      </p>
      {message && <p class="bk-confirm-message">{message}</p>}
      <dl class="bk-details">
        <div>
          <dt>What</dt>
          <dd>{b.eventType.title}</dd>
        </div>
        <div>
          <dt>When</dt>
          <dd>
            {formatRange(b.start, b.end, timezone, hour12)}
            <span class="bk-dd-sub">{zoneLabel(timezone, Date.parse(b.start))}</span>
          </dd>
        </div>
        {loc && (
          <div>
            <dt>Where</dt>
            <dd>
              {locationTitle(loc)}
              {join ? (
                <span class="bk-dd-sub">
                  <a href={join} target="_blank" rel="noopener noreferrer" class="bk-break">
                    {join}
                  </a>
                </span>
              ) : (
                loc.text && loc.text !== locationTitle(loc) && <span class="bk-dd-sub">{loc.text}</span>
              )}
            </dd>
          </div>
        )}
        {hosts.length > 0 && (
          <div>
            <dt>Who</dt>
            <dd>
              {nameList(hosts)}
              {b.invitee && <span class="bk-dd-sub">and you{b.guests.length ? `, with ${b.guests.length} guest${b.guests.length === 1 ? "" : "s"}` : ""}</span>}
            </dd>
          </div>
        )}
      </dl>
      {loc?.sandbox && <SandboxNote>This join link is a placeholder. Real bookings get a {locationTitle(loc)} link from the host's connected account.</SandboxNote>}
      <div class="bk-actions">
        <a class="bk-btn bk-btn-primary bk-btn-md" href={result.icsUrl} download={`${b.eventType.id}.ics`}>
          <Icon name="download" size={16} />
          Add to calendar
        </a>
        {embedded ? (
          <a class="bk-btn bk-btn-secondary bk-btn-md" href={result.manageUrl} target="_blank" rel="noopener">
            Reschedule or cancel
          </a>
        ) : (
          <Link class="bk-btn bk-btn-secondary bk-btn-md" href={result.manageUrl}>
            Reschedule or cancel
          </Link>
        )}
      </div>
    </section>
  );
}
