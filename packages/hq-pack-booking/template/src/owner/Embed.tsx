import { useEffect, useRef, useState } from "preact/hooks";
import { CopyButton, Segmented } from "../ui.tsx";
import { useOwner } from "./context.ts";
import { PageHead, Section } from "./parts.tsx";

type Mode = "inline" | "popup-button" | "popup-text";

declare global {
  interface Window {
    HQBooking?: { init: (root?: Element) => void; open: (id: string, opts?: Record<string, string>) => void; close: () => void };
  }
}

function snippet(mode: Mode, origin: string, id: string): string {
  const script = `<script src="${origin}/embed.js" async></script>`;
  if (mode === "inline") return `<div data-hq-booking="${id}"></div>\n${script}`;
  if (mode === "popup-button") return `<button data-hq-booking="${id}" data-hq-mode="popup-button">Book a time</button>\n${script}`;
  return `<a href="${origin}/${id}" data-hq-booking="${id}" data-hq-mode="popup-text">Book a time with us</a>\n${script}`;
}

const LISTEN = `<script>
  // Fires once a visitor books, for your analytics.
  document.addEventListener("hq-booking:booked", (e) => {
    console.log("booked", e.detail.bookingId, e.detail.eventType, e.detail.start);
  });
</script>`;

function loadEmbed(): Promise<void> {
  if (window.HQBooking) return Promise.resolve();
  return new Promise((ok, fail) => {
    const s = document.createElement("script");
    s.src = "/embed.js";
    s.onload = () => ok();
    s.onerror = () => fail(new Error("embed.js did not load"));
    document.head.appendChild(s);
  });
}

export function Embed() {
  const { session } = useOwner();
  const types = (session.eventTypes ?? []).filter((t) => !t.secret);
  const [id, setId] = useState(types[0]?.id ?? "");
  const [mode, setMode] = useState<Mode>("inline");
  const [booked, setBooked] = useState<string | null>(null);
  const preview = useRef<HTMLDivElement>(null);
  const origin = location.origin;

  useEffect(() => {
    const el = preview.current;
    if (!el) return;
    el.innerHTML = "";
    const node = document.createElement(mode === "popup-text" ? "a" : mode === "popup-button" ? "button" : "div");
    node.setAttribute("data-hq-booking", id);
    if (mode !== "inline") {
      node.setAttribute("data-hq-mode", mode);
      node.textContent = mode === "popup-button" ? "Book a time" : "Book a time with us";
      if (mode === "popup-button") node.className = "hqb-button";
      if (mode === "popup-text") (node as HTMLAnchorElement).href = `${origin}/${id}`;
    }
    el.appendChild(node);
    loadEmbed()
      .then(() => window.HQBooking?.init(el))
      .catch(() => (el.textContent = "The embed script didn't load. Build the pages (npm run build) and reload."));
  }, [id, mode]);

  useEffect(() => {
    const on = (e: Event) => setBooked(`Booked: ${(e as CustomEvent<{ bookingId: string }>).detail.bookingId}`);
    document.addEventListener("hq-booking:booked", on);
    return () => document.removeEventListener("hq-booking:booked", on);
  }, []);

  return (
    <>
      <PageHead title="Embed" sub="Put the booking page on your own site. One script handles all three styles." />
      <div class="ow-embed-controls">
        <label class="ow-filter">
          <span>Event type</span>
          <select class="bk-input" value={id} onChange={(e) => setId((e.currentTarget as HTMLSelectElement).value)}>
            {types.map((t) => (
              <option key={t.id} value={t.id}>
                {t.title}
              </option>
            ))}
            <option value="">All event types (company page)</option>
          </select>
        </label>
        <Segmented
          label="Embed style"
          value={mode}
          options={[
            { value: "inline", label: "Inline" },
            { value: "popup-button", label: "Popup button" },
            { value: "popup-text", label: "Popup link" },
          ]}
          onChange={setMode}
        />
      </div>
      <div class="ow-two ow-two-embed">
        <Section title="Snippet" sub="Paste where the booking page should appear.">
          <pre class="ow-pre-block">{snippet(mode, origin, id)}</pre>
          <CopyButton text={snippet(mode, origin, id)} label="Copy snippet" />
          <h3 class="ow-mini-title">Prefill and tracking</h3>
          <p class="ow-section-sub">
            Add <code>data-hq-name</code>, <code>data-hq-email</code> or <code>data-hq-params="a_company=Acme"</code> to the element. Your page's own <code>utm_*</code>, <code>name</code>, <code>email</code> and <code>a_*</code> URL parameters are passed through and saved on the booking.
          </p>
          <pre class="ow-pre-block">{LISTEN}</pre>
          <CopyButton text={LISTEN} label="Copy listener" />
        </Section>
        <Section title="Live preview" sub={mode === "inline" ? "This is the real booking page, embedded." : "Click to open the popup."}>
          <div class={`ow-embed-preview is-${mode}`} ref={preview} />
          {booked && (
            <p class="ow-saved" role="status">
              {booked}
            </p>
          )}
        </Section>
      </div>
    </>
  );
}
