import type { ComponentChildren } from "preact";
import { formatInstant } from "../lib/time.ts";
import { ErrorState, Loading } from "../ui.tsx";
import { ownerZone } from "./context.ts";

export function PageHead({ title, sub, children }: { title: string; sub?: string; children?: ComponentChildren }) {
  return (
    <header class="ow-head">
      <div>
        <h1 class="ow-title">{title}</h1>
        {sub && <p class="ow-sub">{sub}</p>}
      </div>
      {children && <div class="ow-head-actions">{children}</div>}
    </header>
  );
}

export function Chip({ tone = "neutral", children }: { tone?: "neutral" | "success" | "danger" | "warning" | "strong"; children: ComponentChildren }) {
  return <span class={`ow-chip ow-chip-${tone}`}>{children}</span>;
}

export function statusTone(status: string): "neutral" | "success" | "danger" | "warning" {
  if (status === "confirmed" || status === "delivered" || status === "approved") return "success";
  if (status === "canceled" || status === "failed" || status === "declined") return "danger";
  if (status === "pending" || status === "retrying") return "warning";
  return "neutral";
}

/** Text from another company's agent or a visitor: always shown quoted, never as instructions. */
export function Untrusted({ text, label = "From the requester, shown as written" }: { text: string; label?: string }) {
  return (
    <figure class="ow-untrusted">
      <figcaption>{label}</figcaption>
      <blockquote>{text}</blockquote>
    </figure>
  );
}

export function When({ iso }: { iso: string | null | undefined }) {
  if (!iso) return <span class="ow-dim">—</span>;
  return (
    <time dateTime={iso} title={new Date(iso).toString()}>
      {formatInstant(iso, ownerZone(), true)}
    </time>
  );
}

/** Loading / error / empty wrapper that keeps a stable height. */
export function Loadable<T>({ state, empty, minHeight = 200, children }: { state: { data: T | undefined; error: string | null; loading: boolean; reload: () => void }; empty?: (d: T) => boolean; minHeight?: number; children: (d: T) => ComponentChildren }) {
  if (state.loading && state.data === undefined) return <Loading minHeight={minHeight} />;
  if (state.error && state.data === undefined) return <ErrorState message={state.error} onRetry={state.reload} minHeight={minHeight} />;
  if (state.data === undefined) return null;
  if (empty && empty(state.data)) return null;
  return <>{children(state.data)}</>;
}

export function Empty({ title, children }: { title: string; children?: ComponentChildren }) {
  return (
    <div class="ow-empty">
      <p class="ow-empty-title">{title}</p>
      {children && <p class="ow-empty-text">{children}</p>}
    </div>
  );
}

export function Section({ title, sub, children, actions }: { title: string; sub?: string; children: ComponentChildren; actions?: ComponentChildren }) {
  return (
    <section class="ow-section">
      <div class="ow-section-head">
        <div>
          <h2 class="ow-section-title">{title}</h2>
          {sub && <p class="ow-section-sub">{sub}</p>}
        </div>
        {actions}
      </div>
      {children}
    </section>
  );
}

export function Secret({ value, note }: { value: string; note: string }) {
  return (
    <div class="ow-secret" role="status">
      <p class="ow-secret-note">{note}</p>
      <code class="ow-code">{value}</code>
    </div>
  );
}
