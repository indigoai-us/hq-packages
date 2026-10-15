import { useState } from "preact/hooks";
import { qs } from "../lib/api.ts";
import { useAction, useAsync, useNow } from "../lib/hooks.ts";
import { formatDuration, formatRange, formatTimeLeft, zoneLabel } from "../lib/time.ts";
import { Button, Notice, SandboxNote, Segmented } from "../ui.tsx";
import { ownerZone, useOwner } from "./context.ts";
import { Chip, Empty, Loadable, PageHead, statusTone, Untrusted, When } from "./parts.tsx";

interface Approval {
  id: string;
  status: "pending" | "approved" | "declined" | "expired";
  eventType: string;
  start: string;
  end: string;
  duration: number;
  hostIds: string[];
  requester: { memberId: string; name: string; email: string; company: string; agentKeyId: string };
  topic: { text: string; untrusted: true } | null;
  expiresAt: string;
  createdAt: string;
  decidedAt: string | null;
  bookingId: string | null;
}

export function Approvals() {
  const { call, session } = useOwner();
  const [status, setStatus] = useState<"pending" | "">("pending");
  const res = useAsync(() => call<{ approvals: Approval[] }>(`/api/owner/approvals${qs({ status })}`), [status]);
  const now = useNow(15_000);
  const zone = ownerZone();
  const title = (id: string) => session.eventTypes?.find((e) => e.id === id)?.title ?? id;
  const hostName = (id: string) => session.hosts?.find((h) => h.id === id)?.name ?? id;
  return (
    <>
      <PageHead title="Approvals" sub="Agents from outside your company ask first. The time is held for 24 hours while you decide.">
        <Segmented
          label="Show"
          value={status}
          options={[
            { value: "pending", label: "Waiting" },
            { value: "", label: "All" },
          ]}
          onChange={setStatus}
        />
      </PageHead>
      <SandboxNote>Sandbox approvals: requests come from test agent keys. Real requests come from other HQ members' agents and arrive as an HQ DM with Approve and Decline.</SandboxNote>
      <Loadable state={res} minHeight={300}>
        {(d) =>
          d.approvals.length === 0 ? (
            <Empty title={status === "pending" ? "Nothing waiting" : "No requests yet"}>When an agent from another company asks for a time, it shows up here.</Empty>
          ) : (
            <ul class="ow-cards">
              {d.approvals.map((a) => (
                <ApprovalCard key={a.id} a={a} now={now} zone={zone} title={title(a.eventType)} hosts={a.hostIds.map(hostName).join(", ")} onDone={res.reload} />
              ))}
            </ul>
          )
        }
      </Loadable>
    </>
  );
}

function ApprovalCard({ a, now, zone, title, hosts, onDone }: { a: Approval; now: number; zone: string; title: string; hosts: string; onDone: () => void }) {
  const { call } = useOwner();
  const [declining, setDeclining] = useState(false);
  const [reason, setReason] = useState("");
  const approve = useAction(async () => {
    await call(`/api/owner/approvals/${encodeURIComponent(a.id)}/approve`, { body: {} });
    onDone();
  });
  const decline = useAction(async () => {
    await call(`/api/owner/approvals/${encodeURIComponent(a.id)}/decline`, { body: reason.trim() ? { reason: reason.trim() } : {} });
    onDone();
  });
  const left = Date.parse(a.expiresAt) - now;
  return (
    <li class="ow-card">
      <div class="ow-card-head">
        <div>
          <p class="ow-card-title">
            {a.requester.name}'s agent for {a.requester.name}
          </p>
          <p class="ow-cell-sub">
            {a.requester.email} · {a.requester.company}
          </p>
        </div>
        {a.status === "pending" ? <Chip tone={left < 3_600_000 ? "warning" : "neutral"}>{formatTimeLeft(left)}</Chip> : <Chip tone={statusTone(a.status)}>{a.status}</Chip>}
      </div>
      <dl class="ow-kv">
        <dt>Meeting</dt>
        <dd>
          {title}, {formatDuration(a.duration)}
        </dd>
        <dt>When</dt>
        <dd>
          {formatRange(a.start, a.end, zone, true)}
          <span class="ow-cell-sub">{zoneLabel(zone, Date.parse(a.start))}</span>
        </dd>
        <dt>Host</dt>
        <dd>{hosts}</dd>
        <dt>Asked</dt>
        <dd>
          <When iso={a.createdAt} />
        </dd>
      </dl>
      {a.topic && <Untrusted text={a.topic.text} label="Topic from the requesting agent, shown as written" />}
      {a.status === "pending" && (
        <div class="ow-card-actions">
          {declining ? (
            <form
              class="ow-inline-form"
              onSubmit={(e) => {
                e.preventDefault();
                void decline.run();
              }}
            >
              <label class="ow-filter ow-filter-grow">
                <span>Reason for the requester (optional)</span>
                <input class="bk-input" value={reason} onInput={(e) => setReason((e.currentTarget as HTMLInputElement).value)} />
              </label>
              <Button type="submit" variant="danger" busy={decline.busy}>
                Decline
              </Button>
              <Button variant="ghost" onClick={() => setDeclining(false)}>
                Back
              </Button>
            </form>
          ) : (
            <>
              <Button variant="primary" busy={approve.busy} onClick={() => void approve.run()}>
                Approve and book
              </Button>
              <Button onClick={() => setDeclining(true)}>Decline</Button>
            </>
          )}
        </div>
      )}
      {(approve.error || decline.error) && (
        <Notice tone="danger" live>
          {approve.error ?? decline.error}
        </Notice>
      )}
    </li>
  );
}
