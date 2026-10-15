// Shared building blocks. Overrides can import these as "@booking/ui".

import type { ComponentChildren, JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import { linkClick } from "./lib/router.ts";

const PATHS: Record<string, string> = {
  clock: "M12 7v5l3 2M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
  video: "M15 10l4.55-2.28A1 1 0 0 1 21 8.62v6.76a1 1 0 0 1-1.45.9L15 14M5 18h8a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2Z",
  phone: "M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2Z",
  pin: "M12 21s-7-6.2-7-11a7 7 0 1 1 14 0c0 4.8-7 11-7 11Zm0-8.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z",
  link: "M10 14a4 4 0 0 0 5.66 0l3-3a4 4 0 0 0-5.66-5.66l-1 1M14 10a4 4 0 0 0-5.66 0l-3 3a4 4 0 0 0 5.66 5.66l1-1",
  globe: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0 0c2.5-2.4 3.75-5.4 3.75-9S14.5 5.4 12 3m0 18c-2.5-2.4-3.75-5.4-3.75-9S9.5 5.4 12 3M3.5 9h17M3.5 15h17",
  calendar: "M8 3v3M16 3v3M4 9h16M5 5h14a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1Z",
  user: "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8a7 7 0 0 1 14 0",
  users: "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7Zm-6 9a6 6 0 0 1 12 0M16 4.5a3.5 3.5 0 0 1 0 6.5M18 14.5a6 6 0 0 1 3 5.5",
  check: "M5 12.5l4.5 4.5L19 7.5",
  x: "M6 6l12 12M18 6L6 18",
  left: "M15 18l-6-6 6-6",
  right: "M9 6l6 6-6 6",
  arrow: "M5 12h14M13 6l6 6-6 6",
  back: "M19 12H5M11 6l-6 6 6 6",
  download: "M12 4v11M7 10l5 5 5-5M5 20h14",
  copy: "M9 9h10v10H9zM5 15V5h10",
  mail: "M4 6h16v12H4zM4 7l8 6 8-6",
  bell: "M6 16V11a6 6 0 1 1 12 0v5l1.5 2h-15L6 16Zm4 4h4",
  inbox: "M4 13l2.5-7h11l2.5 7v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-5Zm0 0h5l1 2h4l1-2h5",
  shield: "M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6l7-3Z",
  key: "M15 7a4 4 0 1 1-3.87 5H8v2H6v2H3v-3l5.13-5.13A4 4 0 0 1 15 7Zm1 2h.01",
  hook: "M8 8a4 4 0 1 1 6 3.46V14a4 4 0 1 1-4-4M6 20a2 2 0 1 0 0-4 2 2 0 0 0 0 4Z",
  chart: "M4 20V4M4 20h16M8 16v-4M12 16V8M16 16v-6",
  trash: "M5 7h14M10 11v6M14 11v6M6 7l1 12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1l1-12M9 7V4h6v3",
  play: "M7 5v14l11-7L7 5Z",
  code: "M9 8l-4 4 4 4M15 8l4 4-4 4",
  list: "M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01",
  info: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-5v-5m0-3h.01",
  out: "M15 4h4v16h-4M10 8l-4 4 4 4M6 12h10",
  sandbox: "M4 8l8-4 8 4-8 4-8-4Zm0 0v8l8 4m-8-12 8 4m0 8 8-4V8m-8 12v-8",
  external: "M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5",
  route: "M6 19a2 2 0 1 0 0-4 2 2 0 0 0 0 4ZM18 9a2 2 0 1 0 0-4 2 2 0 0 0 0 4ZM6 15V9a4 4 0 0 1 4-4h6M18 9v6a4 4 0 0 1-4 4H8",
};

export type IconName = keyof typeof PATHS;

export function Icon({ name, size = 16, label }: { name: IconName | string; size?: number; label?: string }) {
  return (
    <svg
      class="bk-icon"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width={1.6}
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden={label ? undefined : "true"}
      role={label ? "img" : undefined}
      aria-label={label}
    >
      <path d={PATHS[name] ?? PATHS.info} />
    </svg>
  );
}

type ButtonProps = JSX.HTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "secondary" | "ghost" | "danger";
  size?: "sm" | "md";
  busy?: boolean;
  type?: "button" | "submit";
  disabled?: boolean;
};

export function Button({ variant = "secondary", size = "md", busy, children, class: cls, disabled, type = "button", ...rest }: ButtonProps) {
  return (
    <button {...rest} type={type} class={`bk-btn bk-btn-${variant} bk-btn-${size} ${cls ?? ""}`} disabled={disabled || busy} aria-busy={busy ? "true" : undefined}>
      {children}
    </button>
  );
}

export function Link({ href, children, class: cls, ...rest }: JSX.HTMLAttributes<HTMLAnchorElement> & { href: string }) {
  return (
    <a href={href} class={cls as string} onClick={linkClick} {...rest}>
      {children}
    </a>
  );
}

/** Calm in-place loading text. Reserve height with `minHeight` to avoid layout shift. */
export function Loading({ label = "Loading…", minHeight }: { label?: string; minHeight?: number }) {
  return (
    <div class="bk-loading" role="status" style={minHeight ? { minHeight } : undefined}>
      <span class="bk-loading-dot" aria-hidden="true" />
      {label}
    </div>
  );
}

/** A plain error message with a retry button. */
export function ErrorState({ message, onRetry, minHeight }: { message: string; onRetry?: () => void; minHeight?: number }) {
  return (
    <div class="bk-error-state" role="alert" style={minHeight ? { minHeight } : undefined}>
      <p>{message}</p>
      {onRetry && (
        <Button size="sm" onClick={onRetry}>
          Try again
        </Button>
      )}
    </div>
  );
}

export function Notice({ tone = "neutral", children, live }: { tone?: "neutral" | "danger" | "success" | "warning"; children: ComponentChildren; live?: boolean }) {
  return (
    <div class={`bk-notice bk-notice-${tone}`} role={live ? (tone === "danger" ? "alert" : "status") : undefined}>
      {children}
    </div>
  );
}

/** A one-line note on every sandbox surface saying what the real version uses. */
export function SandboxNote({ children }: { children: ComponentChildren }) {
  return (
    <p class="bk-sandbox">
      <span class="bk-sandbox-tag">
        <Icon name="sandbox" size={13} />
        Sandbox
      </span>
      <span>{children}</span>
    </p>
  );
}

export function Field({ id, label, hint, error, required, children }: { id: string; label: string; hint?: string; error?: string | null; required?: boolean; children: ComponentChildren }) {
  return (
    <div class={`bk-field${error ? " bk-field-invalid" : ""}`}>
      <label for={id} class="bk-label">
        {label}
        {required ? <span class="bk-required"> (required)</span> : null}
      </label>
      {hint && (
        <p class="bk-hint" id={`${id}-hint`}>
          {hint}
        </p>
      )}
      {children}
      {error && (
        <p class="bk-field-error" id={`${id}-error`}>
          {error}
        </p>
      )}
    </div>
  );
}

export function describedBy(id: string, hint?: string, error?: string | null): string | undefined {
  const ids = [hint ? `${id}-hint` : "", error ? `${id}-error` : ""].filter(Boolean);
  return ids.length ? ids.join(" ") : undefined;
}

export function CopyButton({ text, label = "Copy" }: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  useEffect(() => {
    if (!done) return;
    const t = setTimeout(() => setDone(false), 1800);
    return () => clearTimeout(t);
  }, [done]);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
    }
    setDone(true);
  };
  return (
    <Button size="sm" onClick={copy}>
      <Icon name={done ? "check" : "copy"} size={14} />
      <span aria-live="polite">{done ? "Copied" : label}</span>
    </Button>
  );
}

export function Segmented<T extends string>({ label, value, options, onChange }: { label: string; value: T; options: { value: T; label: string }[]; onChange: (v: T) => void }) {
  return (
    <div class="bk-segmented" role="radiogroup" aria-label={label}>
      {options.map((o) => (
        <button
          type="button"
          role="radio"
          aria-checked={o.value === value}
          class={o.value === value ? "is-on" : ""}
          onClick={() => onChange(o.value)}
          onKeyDown={(e) => {
            if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
            e.preventDefault();
            const i = options.findIndex((x) => x.value === value);
            const next = options[(i + (e.key === "ArrowRight" ? 1 : options.length - 1)) % options.length] as { value: T };
            onChange(next.value);
            ((e.currentTarget as HTMLElement).parentElement?.querySelector(`[aria-checked="false"]`) as HTMLElement | null)?.focus();
          }}
          tabIndex={o.value === value ? 0 : -1}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Avatar({ name, size = 36 }: { name: string; size?: number }) {
  const parts = name.trim().split(/\s+/);
  const text = ((parts[0]?.[0] ?? "") + (parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? "") : "")).toUpperCase();
  return (
    <span class="bk-avatar" style={{ width: size, height: size, fontSize: Math.round(size * 0.38) }} aria-hidden="true">
      {text || "?"}
    </span>
  );
}
