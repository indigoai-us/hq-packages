// Sandbox email outbox and sandbox HQ DMs. In the prototype nothing is
// sent; these screens show exactly what would go out.

import { useState } from "preact/hooks";
import { qs } from "../lib/api.ts";
import { useAsync } from "../lib/hooks.ts";
import { formatInstant } from "../lib/time.ts";
import { Link, SandboxNote } from "../ui.tsx";
import { ownerZone, useOwner } from "./context.ts";

/** DM text carries ISO times; show them in the owner's zone. */
const readable = (text: string) => text.replace(/\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d(?:\.\d+)?)?Z/g, (iso) => formatInstant(iso, ownerZone(), true));
import { Chip, Empty, Loadable, PageHead, When } from "./parts.tsx";

interface Email {
  id: string;
  bookingId: string | null;
  kind: string;
  to: string;
  subject: string;
  html: string;
  text: string;
  createdAt: string;
}

const KIND_LABEL: Record<string, string> = {
  confirmation: "Confirmation",
  reminder: "Reminder",
  "follow-up": "Follow-up",
  followup: "Follow-up",
  canceled: "Cancellation",
  cancellation: "Cancellation",
  rescheduled: "Rescheduled",
  reschedule: "Rescheduled",
};

const kindLabel = (k: string) => KIND_LABEL[k] ?? k.replace(/[-_]/g, " ");

export function Outbox() {
  const { call } = useOwner();
  const res = useAsync(() => call<{ emails: Email[] }>("/api/owner/outbox"), []);
  const [selected, setSelected] = useState<string | null>(null);
  return (
    <>
      <PageHead title="Outbox" sub="Every email the app would send to invitees and guests." />
      <SandboxNote>Sandbox email: stored here, not sent. Real emails go out from the host's Gmail through your HQ Google connection.</SandboxNote>
      <Loadable state={res} minHeight={420}>
        {(d) => {
          if (!d.emails.length) return <Empty title="No emails yet">Book a time on the booking page and the confirmation appears here.</Empty>;
          const emails = [...d.emails].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
          const current = emails.find((e) => e.id === selected) ?? emails[0]!;
          return (
            <div class="ow-mail">
              <ul class="ow-mail-list" aria-label="Emails">
                {emails.map((e) => (
                  <li key={e.id}>
                    <button type="button" class={`ow-mail-item${e.id === current.id ? " is-active" : ""}`} aria-current={e.id === current.id ? "true" : undefined} onClick={() => setSelected(e.id)}>
                      <span class="ow-mail-top">
                        <Chip>{kindLabel(e.kind)}</Chip>
                        <span class="ow-cell-sub">
                          <When iso={e.createdAt} />
                        </span>
                      </span>
                      <span class="ow-mail-subject">{e.subject}</span>
                      <span class="ow-cell-sub">To {e.to || "deleted invitee"}</span>
                    </button>
                  </li>
                ))}
              </ul>
              <article class="ow-mail-view" aria-label="Email preview">
                <dl class="ow-mail-meta">
                  <dt>Subject</dt>
                  <dd class="ow-strong">{current.subject}</dd>
                  <dt>To</dt>
                  <dd>{current.to || "Deleted invitee"}</dd>
                  <dt>Kind</dt>
                  <dd>{kindLabel(current.kind)}</dd>
                  {current.bookingId && (
                    <>
                      <dt>Booking</dt>
                      <dd>
                        <Link href={`/owner/bookings/${encodeURIComponent(current.bookingId)}`} class="bk-textlink">
                          Open booking
                        </Link>
                      </dd>
                    </>
                  )}
                </dl>
                <iframe class="ow-mail-frame" title={`Email: ${current.subject}`} sandbox="" srcdoc={current.html || `<pre style="font:14px system-ui;white-space:pre-wrap">${current.text.replace(/[<&]/g, (c) => (c === "<" ? "&lt;" : "&amp;"))}</pre>`} />
              </article>
            </div>
          );
        }}
      </Loadable>
    </>
  );
}

interface Dm {
  id: string;
  recipient: { type: string; id: string };
  kind: string;
  title: string;
  body: string;
  data: unknown;
  bookingId: string | null;
  approvalId: string | null;
  createdAt: string;
}

const DM_LABEL: Record<string, string> = {
  booked: "New booking",
  "booking-created": "New booking",
  "booking-canceled": "Canceled",
  "booking-rescheduled": "Rescheduled",
  "host-brief": "Host brief",
  brief: "Host brief",
  "approval-request": "Approval request",
  "approval-approved": "Approved",
  "approval-declined": "Declined",
  "approval-expired": "Request expired",
  "needs-member-approval": "Needs your OK",
  approval: "Approval request",
  canceled: "Canceled",
  rescheduled: "Rescheduled",
};

export function Notifications() {
  const { call, session } = useOwner();
  const [recipient, setRecipient] = useState("");
  const res = useAsync(() => call<{ notifications: Dm[] }>(`/api/owner/notifications${qs({ recipient })}`), [recipient]);
  const hostName = (id: string) => session.hosts?.find((h) => h.id === id)?.name ?? id;
  return (
    <>
      <PageHead title="Notifications" sub="HQ direct messages to hosts and members: new bookings, briefs before meetings and approval requests.">
        <label class="ow-filter">
          <span>Recipient</span>
          <select class="bk-input" value={recipient} onChange={(e) => setRecipient((e.currentTarget as HTMLSelectElement).value)}>
            <option value="">Everyone</option>
            {(session.hosts ?? []).map((h) => (
              <option key={h.id} value={h.id}>
                {h.name}
              </option>
            ))}
          </select>
        </label>
      </PageHead>
      <SandboxNote>Sandbox HQ DMs: shown here only. Real ones arrive in the recipient's HQ direct messages.</SandboxNote>
      <Loadable state={res} minHeight={360}>
        {(d) =>
          d.notifications.length === 0 ? (
            <Empty title="No messages yet">Hosts get a DM when someone books, and a brief before each meeting.</Empty>
          ) : (
            <ul class="ow-dms">
              {[...d.notifications]
                .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
                .map((n) => (
                  <li key={n.id} class="ow-dm">
                    <div class="ow-dm-head">
                      <span class="ow-dm-from" aria-hidden="true">
                        HQ
                      </span>
                      <span class="ow-dm-to">
                        <span class="ow-strong">HQ Booking</span>
                        <span class="ow-cell-sub">
                          to {n.recipient.type === "host" ? hostName(n.recipient.id) : n.recipient.id} · <When iso={n.createdAt} />
                        </span>
                      </span>
                      <Chip tone={n.kind.includes("approval") ? "warning" : "neutral"}>{DM_LABEL[n.kind] ?? n.kind.replace(/[-_]/g, " ")}</Chip>
                    </div>
                    <p class="ow-dm-title">{readable(n.title)}</p>
                    <p class="ow-dm-body">{readable(n.body)}</p>
                    <div class="ow-dm-links">
                      {n.approvalId && (
                        <Link href="/owner/approvals" class="bk-textlink">
                          Review request
                        </Link>
                      )}
                      {n.bookingId && (
                        <Link href={`/owner/bookings/${encodeURIComponent(n.bookingId)}`} class="bk-textlink">
                          Open booking
                        </Link>
                      )}
                    </div>
                  </li>
                ))}
            </ul>
          )
        }
      </Loadable>
    </>
  );
}
