// Links, agent keys and delegations, webhooks, data deletion and jobs.

import { useState } from "preact/hooks";
import { useAction, useAsync } from "../lib/hooks.ts";
import { Button, CopyButton, Field, Notice, SandboxNote } from "../ui.tsx";
import { useOwner } from "./context.ts";
import { Chip, Empty, Loadable, PageHead, Secret, Section, statusTone, When } from "./parts.tsx";

/* ---------------------------------------------------------------- Links */

interface LinkRow {
  id: string;
  eventType: string;
  singleUse: boolean;
  expiresAt: string | null;
  usedAt: string | null;
  usedBy: string | null;
  revokedAt: string | null;
  createdAt: string;
}

function linkState(l: LinkRow): { label: string; tone: "neutral" | "success" | "danger" | "warning" } {
  if (l.revokedAt) return { label: "Revoked", tone: "danger" };
  if (l.usedAt && l.singleUse) return { label: "Used", tone: "neutral" };
  if (l.expiresAt && Date.parse(l.expiresAt) < Date.now()) return { label: "Expired", tone: "neutral" };
  return { label: "Active", tone: "success" };
}

export function Links() {
  const { call, session } = useOwner();
  const types = session.eventTypes ?? [];
  const list = useAsync(() => call<{ links: LinkRow[] }>("/api/owner/links"), []);
  const [eventType, setEventType] = useState(types.find((t) => t.secret)?.id ?? types[0]?.id ?? "");
  const [singleUse, setSingleUse] = useState(true);
  const [hours, setHours] = useState("168");
  const [minted, setMinted] = useState<string | null>(null);
  const mint = useAction(async () => {
    const h = Number(hours);
    const r = await call<{ path: string }>("/api/owner/links", { body: { eventType, singleUse, ...(hours && h > 0 ? { expiresInHours: h } : {}) } });
    setMinted(`${location.origin}${r.path}`);
    list.reload();
  });
  const revoke = useAction(async (id: string) => {
    await call(`/api/owner/links/${encodeURIComponent(id)}/revoke`, { body: {} });
    list.reload();
  });
  const title = (id: string) => types.find((t) => t.id === id)?.title ?? id;
  return (
    <>
      <PageHead title="Links" sub="Private links for one person or a short time. Secret event types are only reachable this way." />
      <Section title="Make a link">
        <form
          class="ow-form-grid"
          onSubmit={(e) => {
            e.preventDefault();
            setMinted(null);
            void mint.run();
          }}
        >
          <Field id="ow-link-type" label="Event type">
            <select id="ow-link-type" class="bk-input" value={eventType} onChange={(e) => setEventType((e.currentTarget as HTMLSelectElement).value)}>
              {types.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.title}
                  {t.secret ? " (secret)" : ""}
                </option>
              ))}
            </select>
          </Field>
          <Field id="ow-link-hours" label="Expires after (hours)" hint="Leave empty for no expiry.">
            <input id="ow-link-hours" class="bk-input" inputMode="numeric" value={hours} onInput={(e) => setHours((e.currentTarget as HTMLInputElement).value.replace(/\D/g, ""))} aria-describedby="ow-link-hours-hint" />
          </Field>
          <label class="bk-option ow-form-check">
            <input type="checkbox" checked={singleUse} onChange={(e) => setSingleUse((e.currentTarget as HTMLInputElement).checked)} />
            <span>Single use: the link stops working after one booking</span>
          </label>
          <div class="ow-form-actions">
            <Button type="submit" variant="primary" busy={mint.busy}>
              Make link
            </Button>
          </div>
        </form>
        {mint.error && (
          <Notice tone="danger" live>
            {mint.error}
          </Notice>
        )}
        {minted && (
          <div class="ow-minted" role="status">
            <p class="ow-secret-note">Copy it now. The link is shown once; only a fingerprint is kept.</p>
            <div class="ow-copy-row">
              <code class="ow-code">{minted}</code>
              <CopyButton text={minted} />
            </div>
          </div>
        )}
      </Section>
      <Section title="Links you've made">
        <Loadable state={list} minHeight={160}>
          {(d) =>
            d.links.length === 0 ? (
              <Empty title="No links yet" />
            ) : (
              <div class="ow-table-wrap">
                <table class="ow-table">
                  <thead>
                    <tr>
                      <th scope="col">Event type</th>
                      <th scope="col">Kind</th>
                      <th scope="col">Expires</th>
                      <th scope="col">Status</th>
                      <th scope="col">
                        <span class="bk-sr">Actions</span>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {d.links.map((l) => {
                      const st = linkState(l);
                      return (
                        <tr key={l.id}>
                          <td>{title(l.eventType)}</td>
                          <td>{l.singleUse ? "Single use" : "Reusable"}</td>
                          <td>
                            <When iso={l.expiresAt} />
                          </td>
                          <td>
                            <Chip tone={st.tone}>{st.label}</Chip>
                            {l.usedBy && <span class="ow-cell-sub">by {l.usedBy}</span>}
                          </td>
                          <td class="ow-right">
                            {st.label === "Active" && (
                              <Button size="sm" variant="ghost" onClick={() => void revoke.run(l.id)}>
                                Revoke
                              </Button>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )
          }
        </Loadable>
      </Section>
    </>
  );
}

/* --------------------------------------------------------------- Agents */

interface AgentKey {
  id: string;
  memberId: string;
  memberName: string;
  memberEmail: string;
  memberCompany: string;
  label: string | null;
  createdAt: string;
  revokedAt: string | null;
}

interface Limits {
  eventTypes?: string[];
  maxDuration?: number;
  maxPerWeek?: number;
  hours?: string;
  days?: string[];
  timezone?: string;
  companies?: string[];
}

interface Delegation {
  memberId: string;
  enabled: boolean;
  limits: Limits | null;
  updatedAt: string;
}

const DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

export function Agents() {
  const { call, session } = useOwner();
  const keys = useAsync(() => call<{ agentKeys: AgentKey[] }>("/api/owner/agent-keys"), []);
  const dels = useAsync(() => call<{ delegations: Delegation[] }>("/api/owner/delegations"), []);
  const [form, setForm] = useState({ memberId: "", memberName: "", memberEmail: "", memberCompany: "", label: "" });
  const [secret, setSecret] = useState<string | null>(null);
  const mint = useAction(async () => {
    const body = { memberId: form.memberId.trim(), memberName: form.memberName.trim(), memberEmail: form.memberEmail.trim(), ...(form.memberCompany.trim() ? { memberCompany: form.memberCompany.trim() } : {}), ...(form.label.trim() ? { label: form.label.trim() } : {}) };
    const r = await call<{ key: string }>("/api/owner/agent-keys", { body });
    setSecret(r.key);
    setForm({ memberId: "", memberName: "", memberEmail: "", memberCompany: "", label: "" });
    keys.reload();
    dels.reload();
  });
  const revoke = useAction(async (id: string) => {
    await call(`/api/owner/agent-keys/${encodeURIComponent(id)}/revoke`, { body: {} });
    keys.reload();
  });
  const members = new Map<string, AgentKey>();
  for (const k of keys.data?.agentKeys ?? []) if (!members.has(k.memberId)) members.set(k.memberId, k);
  const input = (k: keyof typeof form, label: string, opts: { hint?: string; type?: string; required?: boolean } = {}) => (
    <Field id={`ow-ak-${k}`} label={label} hint={opts.hint} required={opts.required}>
      <input id={`ow-ak-${k}`} class="bk-input" type={opts.type ?? "text"} value={form[k]} required={opts.required} onInput={(e) => setForm({ ...form, [k]: (e.currentTarget as HTMLInputElement).value })} aria-describedby={opts.hint ? `ow-ak-${k}-hint` : undefined} />
    </Field>
  );
  return (
    <>
      <PageHead title="Agents" sub="Keys that let a member's HQ agent book with you on their behalf, inside the limits you set." />
      <SandboxNote>Sandbox agent keys: for testing agent-to-agent booking. Real agents sign in with their HQ identity and the member's delegation.</SandboxNote>
      <Section title="New agent key" sub="The key stands for one member's agent acting for that member.">
        <form
          class="ow-form-grid"
          onSubmit={(e) => {
            e.preventDefault();
            setSecret(null);
            void mint.run();
          }}
        >
          {input("memberName", "Member name", { required: true })}
          {input("memberEmail", "Member email", { type: "email", required: true })}
          {input("memberId", "Member id", { hint: "Lowercase letters, digits and dashes, like dana-lee.", required: true })}
          {input("memberCompany", "Member's company", { hint: `Company slug. Empty means ${session.company}.` })}
          {input("label", "Label", { hint: "Optional, for your own reference." })}
          <div class="ow-form-actions">
            <Button type="submit" variant="primary" busy={mint.busy}>
              Make key
            </Button>
          </div>
        </form>
        {mint.error && (
          <Notice tone="danger" live>
            {mint.error}
          </Notice>
        )}
        {secret && (
          <div class="ow-minted" role="status">
            <p class="ow-secret-note">Copy the key now and give it to the member's agent. It is shown once.</p>
            <div class="ow-copy-row">
              <code class="ow-code">{secret}</code>
              <CopyButton text={secret} />
            </div>
          </div>
        )}
      </Section>
      <Section title="Keys">
        <Loadable state={keys} minHeight={120}>
          {(d) =>
            d.agentKeys.length === 0 ? (
              <Empty title="No agent keys yet" />
            ) : (
              <div class="ow-table-wrap">
                <table class="ow-table">
                  <thead>
                    <tr>
                      <th scope="col">Member</th>
                      <th scope="col">Company</th>
                      <th scope="col">Label</th>
                      <th scope="col">Made</th>
                      <th scope="col">Status</th>
                      <th scope="col">
                        <span class="bk-sr">Actions</span>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {d.agentKeys.map((k) => (
                      <tr key={k.id}>
                        <td>
                          <span class="ow-strong">{k.memberName}</span>
                          <span class="ow-cell-sub">{k.memberEmail}</span>
                        </td>
                        <td>{k.memberCompany}</td>
                        <td>{k.label ?? <span class="ow-dim">—</span>}</td>
                        <td>
                          <When iso={k.createdAt} />
                        </td>
                        <td>{k.revokedAt ? <Chip tone="danger">Revoked</Chip> : <Chip tone="success">Active</Chip>}</td>
                        <td class="ow-right">
                          {!k.revokedAt && (
                            <Button size="sm" variant="ghost" onClick={() => void revoke.run(k.id)}>
                              Revoke
                            </Button>
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )
          }
        </Loadable>
      </Section>
      <Section title="Member limits" sub="Delegation is off until you turn it on. Requests outside these limits go to the member as a question.">
        <Loadable state={dels} minHeight={120}>
          {(d) => {
            const ids = new Set([...members.keys(), ...d.delegations.map((x) => x.memberId)]);
            if (!ids.size) return <Empty title="No members yet">Make an agent key first.</Empty>;
            return (
              <ul class="ow-cards">
                {[...ids].map((id) => (
                  <DelegationCard key={id} memberId={id} name={members.get(id)?.memberName ?? id} current={d.delegations.find((x) => x.memberId === id)} onSaved={dels.reload} />
                ))}
              </ul>
            );
          }}
        </Loadable>
      </Section>
    </>
  );
}

function DelegationCard({ memberId, name, current, onSaved }: { memberId: string; name: string; current?: Delegation; onSaved: () => void }) {
  const { call, session } = useOwner();
  const l = current?.limits ?? {};
  const [enabled, setEnabled] = useState(current?.enabled ?? false);
  const [maxDuration, setMaxDuration] = useState(l.maxDuration ? String(l.maxDuration) : "");
  const [maxPerWeek, setMaxPerWeek] = useState(l.maxPerWeek ? String(l.maxPerWeek) : "");
  const [hours, setHours] = useState(l.hours ?? "");
  const [days, setDays] = useState<string[]>(l.days ?? []);
  const [types, setTypes] = useState<string[]>(l.eventTypes ?? []);
  const [companies, setCompanies] = useState((l.companies ?? []).join(", "));
  const [saved, setSaved] = useState(false);
  const save = useAction(async () => {
    const limits: Limits = {};
    if (maxDuration) limits.maxDuration = Number(maxDuration);
    if (maxPerWeek) limits.maxPerWeek = Number(maxPerWeek);
    if (hours.trim()) limits.hours = hours.trim();
    if (days.length) limits.days = days;
    if (types.length) limits.eventTypes = types;
    const cos = companies.split(/[\s,]+/).filter(Boolean);
    if (cos.length) limits.companies = cos;
    await call(`/api/owner/delegations/${encodeURIComponent(memberId)}`, { method: "PUT", body: { enabled, limits } });
    setSaved(true);
    onSaved();
  });
  const toggle = (list: string[], v: string) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);
  const p = `ow-del-${memberId}`;
  return (
    <li class="ow-card">
      <form
        onSubmit={(e) => {
          e.preventDefault();
          setSaved(false);
          void save.run();
        }}
      >
        <div class="ow-card-head">
          <p class="ow-card-title">{name}'s agent</p>
          <label class="ow-switch">
            <input type="checkbox" role="switch" checked={enabled} onChange={(e) => setEnabled((e.currentTarget as HTMLInputElement).checked)} />
            <span>{enabled ? "Can book" : "Off"}</span>
          </label>
        </div>
        <div class="ow-form-grid">
          <Field id={`${p}-dur`} label="Longest meeting (minutes)">
            <input id={`${p}-dur`} class="bk-input" inputMode="numeric" value={maxDuration} onInput={(e) => setMaxDuration((e.currentTarget as HTMLInputElement).value.replace(/\D/g, ""))} />
          </Field>
          <Field id={`${p}-week`} label="Meetings per week">
            <input id={`${p}-week`} class="bk-input" inputMode="numeric" value={maxPerWeek} onInput={(e) => setMaxPerWeek((e.currentTarget as HTMLInputElement).value.replace(/\D/g, ""))} />
          </Field>
          <Field id={`${p}-hours`} label="Hours" hint="Like 09:00-17:00.">
            <input id={`${p}-hours`} class="bk-input" value={hours} onInput={(e) => setHours((e.currentTarget as HTMLInputElement).value)} aria-describedby={`${p}-hours-hint`} />
          </Field>
          <Field id={`${p}-cos`} label="Companies it may book with" hint="Slugs, comma separated. Empty means any.">
            <input id={`${p}-cos`} class="bk-input" value={companies} onInput={(e) => setCompanies((e.currentTarget as HTMLInputElement).value)} aria-describedby={`${p}-cos-hint`} />
          </Field>
        </div>
        <fieldset class="bk-fieldset">
          <legend class="bk-label">Days</legend>
          <div class="ow-checks">
            {DAYS.map((d) => (
              <label key={d} class="bk-option">
                <input type="checkbox" checked={days.includes(d)} onChange={() => setDays(toggle(days, d))} />
                <span>{d[0]!.toUpperCase() + d.slice(1)}</span>
              </label>
            ))}
          </div>
        </fieldset>
        <fieldset class="bk-fieldset">
          <legend class="bk-label">Event types</legend>
          <div class="ow-checks">
            {(session.eventTypes ?? []).map((t) => (
              <label key={t.id} class="bk-option">
                <input type="checkbox" checked={types.includes(t.id)} onChange={() => setTypes(toggle(types, t.id))} />
                <span>{t.title}</span>
              </label>
            ))}
          </div>
        </fieldset>
        <div class="ow-card-actions">
          <Button type="submit" busy={save.busy}>
            Save limits
          </Button>
          {saved && <span class="ow-saved" role="status">Saved</span>}
        </div>
        {save.error && (
          <Notice tone="danger" live>
            {save.error}
          </Notice>
        )}
      </form>
    </li>
  );
}

/* ------------------------------------------------------------- Webhooks */

interface Hook {
  id: string;
  url: string;
  events: string[];
  active: boolean;
  createdAt: string;
}

interface Delivery {
  id: string;
  endpointId: string;
  event: string;
  status: "pending" | "delivered" | "failed";
  attempts: number;
  nextAttemptAt: string | null;
  lastStatus: number | null;
  lastError: string | null;
  createdAt: string;
  deliveredAt: string | null;
  payload: unknown;
}

const EVENTS = ["booked", "canceled", "rescheduled", "no-show"];

export function Webhooks() {
  const { call } = useOwner();
  const hooks = useAsync(() => call<{ configured: { id: string; url: string; events: string[]; signingSecret: string; secretBound: boolean }[]; webhooks: Hook[] }>("/api/owner/webhooks"), []);
  const deliveries = useAsync(() => call<{ deliveries: Delivery[] }>("/api/owner/webhook-deliveries"), []);
  const [url, setUrl] = useState("");
  const [events, setEvents] = useState<string[]>(EVENTS);
  const [secret, setSecret] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const add = useAction(async () => {
    const r = await call<{ signingSecret: string }>("/api/owner/webhooks", { body: { url: url.trim(), events } });
    setSecret(r.signingSecret);
    setUrl("");
    hooks.reload();
  });
  const patch = useAction(async (id: string, active: boolean) => {
    await call(`/api/owner/webhooks/${encodeURIComponent(id)}`, { method: "PATCH", body: { active } });
    hooks.reload();
  });
  const del = useAction(async (id: string) => {
    await call(`/api/owner/webhooks/${encodeURIComponent(id)}`, { method: "DELETE" });
    hooks.reload();
  });
  const urlFor = (endpointId: string) => hooks.data?.webhooks.find((h) => h.id === endpointId)?.url ?? hooks.data?.configured.find((h) => h.id === endpointId)?.url ?? endpointId;
  return (
    <>
      <PageHead title="Webhooks" sub="Signed POSTs to your own systems when bookings change. Failed deliveries retry after 1, 5, 30, 120 and 720 minutes." />
      <Section title="Add an endpoint">
        <form
          class="ow-form-grid"
          onSubmit={(e) => {
            e.preventDefault();
            setSecret(null);
            void add.run();
          }}
        >
          <Field id="ow-wh-url" label="URL" hint="A public https address.">
            <input id="ow-wh-url" class="bk-input" type="url" placeholder="https://example.com/hooks/booking" value={url} required onInput={(e) => setUrl((e.currentTarget as HTMLInputElement).value)} aria-describedby="ow-wh-url-hint" />
          </Field>
          <fieldset class="bk-fieldset">
            <legend class="bk-label">Events</legend>
            <div class="ow-checks">
              {EVENTS.map((ev) => (
                <label key={ev} class="bk-option">
                  <input type="checkbox" checked={events.includes(ev)} onChange={() => setEvents(events.includes(ev) ? events.filter((x) => x !== ev) : [...events, ev])} />
                  <span>{ev}</span>
                </label>
              ))}
            </div>
          </fieldset>
          <div class="ow-form-actions">
            <Button type="submit" variant="primary" busy={add.busy}>
              Add endpoint
            </Button>
          </div>
        </form>
        {add.error && (
          <Notice tone="danger" live>
            {add.error}
          </Notice>
        )}
        {secret && <Secret value={secret} note="Signing secret. Copy it now; it is shown once. Check x-hq-booking-signature with it." />}
        {secret && <CopyButton text={secret} label="Copy secret" />}
      </Section>
      <Section title="Endpoints">
        <Loadable state={hooks} minHeight={100}>
          {(d) =>
            d.configured.length + d.webhooks.length === 0 ? (
              <Empty title="No endpoints yet" />
            ) : (
              <ul class="ow-list">
                {d.configured.map((h) => (
                  <li key={h.id} class="ow-list-row">
                    <span>
                      <span class="ow-strong ow-break">{h.url}</span>
                      <span class="ow-cell-sub">
                        From booking.yaml · {h.events.join(", ")} · secret {h.signingSecret} {h.secretBound ? "bound" : "not bound yet"}
                      </span>
                    </span>
                    <Chip tone={h.secretBound ? "success" : "warning"}>{h.secretBound ? "Active" : "Needs secret"}</Chip>
                  </li>
                ))}
                {d.webhooks.map((h) => (
                  <li key={h.id} class="ow-list-row">
                    <span>
                      <span class="ow-strong ow-break">{h.url}</span>
                      <span class="ow-cell-sub">{h.events.join(", ")}</span>
                    </span>
                    <span class="ow-row-actions">
                      <label class="ow-switch">
                        <input type="checkbox" role="switch" checked={h.active} onChange={(e) => void patch.run(h.id, (e.currentTarget as HTMLInputElement).checked)} />
                        <span>{h.active ? "Active" : "Paused"}</span>
                      </label>
                      <Button size="sm" variant="ghost" onClick={() => void del.run(h.id)}>
                        Delete
                      </Button>
                    </span>
                  </li>
                ))}
              </ul>
            )
          }
        </Loadable>
      </Section>
      <Section title="Deliveries" actions={<Button size="sm" variant="ghost" onClick={deliveries.reload}>Refresh</Button>}>
        <Loadable state={deliveries} minHeight={140}>
          {(d) =>
            d.deliveries.length === 0 ? (
              <Empty title="No deliveries yet">Each booking change sends one delivery per endpoint.</Empty>
            ) : (
              <div class="ow-table-wrap">
                <table class="ow-table">
                  <thead>
                    <tr>
                      <th scope="col">Event</th>
                      <th scope="col">Endpoint</th>
                      <th scope="col">Status</th>
                      <th scope="col">Attempts</th>
                      <th scope="col">Last answer</th>
                      <th scope="col">Next try</th>
                      <th scope="col">
                        <span class="bk-sr">Payload</span>
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {d.deliveries.map((x) => (
                      <>
                        <tr key={x.id}>
                          <td>
                            {x.event}
                            <span class="ow-cell-sub">
                              <When iso={x.createdAt} />
                            </span>
                          </td>
                          <td class="ow-break ow-cell-narrow">{urlFor(x.endpointId)}</td>
                          <td>
                            <Chip tone={statusTone(x.status === "pending" && x.attempts > 0 ? "retrying" : x.status)}>{x.status === "pending" && x.attempts > 0 ? "retrying" : x.status}</Chip>
                          </td>
                          <td>{x.attempts}</td>
                          <td>
                            {x.lastStatus ?? "—"}
                            {x.lastError && <span class="ow-cell-sub">{x.lastError}</span>}
                          </td>
                          <td>{x.status === "pending" ? <When iso={x.nextAttemptAt} /> : <span class="ow-dim">—</span>}</td>
                          <td class="ow-right">
                            <Button size="sm" variant="ghost" aria-expanded={open === x.id} onClick={() => setOpen(open === x.id ? null : x.id)}>
                              {open === x.id ? "Hide" : "Payload"}
                            </Button>
                          </td>
                        </tr>
                        {open === x.id && (
                          <tr key={`${x.id}-p`}>
                            <td colSpan={7}>
                              <pre class="ow-pre-block">{JSON.stringify(x.payload, null, 2)}</pre>
                            </td>
                          </tr>
                        )}
                      </>
                    ))}
                  </tbody>
                </table>
              </div>
            )
          }
        </Loadable>
      </Section>
    </>
  );
}

/* ----------------------------------------------------------------- Data */

export function Data() {
  const { call } = useOwner();
  const [email, setEmail] = useState("");
  const [confirming, setConfirming] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const del = useAction(async () => {
    const r = await call<{ redacted: number; bookings: string[] }>("/api/owner/invitee-data/delete", { body: { email: email.trim() } });
    setResult(r.redacted ? `Deleted the invitee data on ${r.redacted} booking${r.redacted === 1 ? "" : "s"}. The bookings stay, with "Deleted invitee" as the name.` : "No bookings use that email. Nothing was changed.");
    setConfirming(false);
    setEmail("");
  });
  const [purge, setPurge] = useState<string | null>(null);
  const run = useAction(async () => {
    const r = await call<{ redacted: number; skipped?: string }>("/api/owner/retention/run", { body: {} });
    setPurge(r.skipped ? "No retention period is set (dataRetention.inviteeDataDays in booking.yaml), so nothing was purged." : `Purge done: ${r.redacted} booking${r.redacted === 1 ? "" : "s"} past the retention period had their invitee data removed.`);
  });
  return (
    <>
      <PageHead title="Data" sub="Invitee personal data is kept apart from bookings, so it can be removed without losing your records." />
      <Section title="Delete an invitee's data" sub="Removes the name, email, answers and guests on every booking with this email, and blanks the stored emails and DMs.">
        <form
          class="ow-inline-form"
          onSubmit={(e) => {
            e.preventDefault();
            setResult(null);
            if (email.trim()) setConfirming(true);
          }}
        >
          <label class="ow-filter ow-filter-grow">
            <span>Invitee email</span>
            <input class="bk-input" type="email" value={email} onInput={(e) => setEmail((e.currentTarget as HTMLInputElement).value)} required />
          </label>
          {!confirming && (
            <Button type="submit" variant="danger">
              Delete data
            </Button>
          )}
        </form>
        {confirming && (
          <div class="ow-confirm-bar" role="alertdialog" aria-label="Confirm deletion">
            <span>Delete everything stored about {email.trim()}? This can't be undone.</span>
            <Button variant="danger" busy={del.busy} onClick={() => void del.run()}>
              Yes, delete
            </Button>
            <Button variant="ghost" onClick={() => setConfirming(false)}>
              Cancel
            </Button>
          </div>
        )}
        {del.error && (
          <Notice tone="danger" live>
            {del.error}
          </Notice>
        )}
        {result && (
          <Notice tone="success" live>
            {result}
          </Notice>
        )}
      </Section>
      <Section title="Retention purge" sub="Runs automatically with the scheduled jobs. Run it now to check what it does.">
        <Button busy={run.busy} onClick={() => void run.run()}>
          Run retention purge
        </Button>
        {run.error && (
          <Notice tone="danger" live>
            {run.error}
          </Notice>
        )}
        {purge && (
          <Notice tone="neutral" live>
            {purge}
          </Notice>
        )}
      </Section>
    </>
  );
}

/* ----------------------------------------------------------------- Jobs */

interface JobRun {
  reclaimed: { holds: number; approvals: number };
  jobs: { done: number; skipped: number; failed: number };
  webhooks: { delivered: number; retrying: number; failed: number };
  retention: { redacted: number };
  countersPurged: number;
  ranAt: string;
}

export function Jobs() {
  const { call } = useOwner();
  const [last, setLast] = useState<JobRun | null>(null);
  const run = useAction(async () => setLast(await call<JobRun>("/api/owner/jobs/run", { body: {} })));
  return (
    <>
      <PageHead title="Jobs" sub="Reminders, follow-ups, host briefs, webhook retries and expired holds. A scheduled job runs these every few minutes." />
      <SandboxNote>On hq-deploy an Outpost scheduled job calls this every few minutes; the dev server runs it every 30 seconds.</SandboxNote>
      <Button variant="primary" busy={run.busy} onClick={() => void run.run()}>
        Run due jobs now
      </Button>
      {run.error && (
        <Notice tone="danger" live>
          {run.error}
        </Notice>
      )}
      {last && (
        <div class="ow-tiles ow-tiles-sm" role="status" aria-label="Last run">
          <div class="ow-tile">
            <span class="ow-tile-label">Messages sent</span>
            <span class="ow-tile-value">{last.jobs.done}</span>
            <span class="ow-tile-sub">
              {last.jobs.skipped} skipped, {last.jobs.failed} failed
            </span>
          </div>
          <div class="ow-tile">
            <span class="ow-tile-label">Webhooks</span>
            <span class="ow-tile-value">{last.webhooks.delivered}</span>
            <span class="ow-tile-sub">
              delivered, {last.webhooks.retrying} retrying, {last.webhooks.failed} failed
            </span>
          </div>
          <div class="ow-tile">
            <span class="ow-tile-label">Released</span>
            <span class="ow-tile-value">{last.reclaimed.holds + last.reclaimed.approvals}</span>
            <span class="ow-tile-sub">
              {last.reclaimed.holds} holds, {last.reclaimed.approvals} approvals
            </span>
          </div>
          <div class="ow-tile">
            <span class="ow-tile-label">Retention</span>
            <span class="ow-tile-value">{last.retention.redacted}</span>
            <span class="ow-tile-sub">
              redacted · ran <When iso={last.ranAt} />
            </span>
          </div>
        </div>
      )}
    </>
  );
}
