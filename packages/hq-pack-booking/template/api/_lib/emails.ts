// Email text for invitees, in the company's theme. Every value is escaped;
// nothing the invitee or an agent typed is ever treated as markup.

import type { BookingConfig } from "./engine.ts";
import { escapeHtml } from "./util.ts";

export type EmailKind = "confirmation" | "cancellation" | "reschedule" | "reminder" | "follow-up";

export interface EmailData {
  config: BookingConfig;
  kind: EmailKind;
  eventTitle: string;
  start: number;
  end: number;
  timezone: string;
  attendeeName: string;
  hostNames: string[];
  location: string;
  manageUrl?: string;
  reason?: string;
  sandbox: boolean;
}

export function formatWhen(start: number, end: number, timeZone: string): string {
  const day = new Intl.DateTimeFormat("en-US", { timeZone, weekday: "long", month: "long", day: "numeric", year: "numeric" }).format(start);
  const time = new Intl.DateTimeFormat("en-US", { timeZone, hour: "numeric", minute: "2-digit" });
  return `${day}, ${time.format(start)} to ${time.format(end)} (${timeZone})`;
}

function lines(d: EmailData): { subject: string; intro: string } {
  const who = d.hostNames.join(", ");
  switch (d.kind) {
    case "confirmation":
      return { subject: `Booked: ${d.eventTitle} with ${who}`, intro: `Your ${d.eventTitle} with ${who} is booked.` };
    case "cancellation":
      return { subject: `Canceled: ${d.eventTitle} with ${who}`, intro: `Your ${d.eventTitle} with ${who} was canceled.` };
    case "reschedule":
      return { subject: `New time: ${d.eventTitle} with ${who}`, intro: `Your ${d.eventTitle} with ${who} moved to a new time.` };
    case "reminder":
      return { subject: `Reminder: ${d.eventTitle} with ${who}`, intro: `This is a reminder of your ${d.eventTitle} with ${who}.` };
    case "follow-up":
      return { subject: `Thanks for meeting with ${who}`, intro: `Thanks for your time at ${d.eventTitle}.` };
  }
}

export function renderEmail(d: EmailData): { subject: string; html: string; text: string } {
  const { subject, intro } = lines(d);
  const theme = (d.config.theme ?? {}) as { colors?: Record<string, string>; fonts?: { body?: string } };
  const primary = theme.colors?.primary ?? "#1f2937";
  const background = theme.colors?.background ?? "#ffffff";
  const textColor = theme.colors?.text ?? "#111827";
  const font = theme.fonts?.body ?? "system-ui, sans-serif";
  const when = formatWhen(d.start, d.end, d.timezone);
  const rows: [string, string][] = [
    ["When", when],
    ["Where", d.location],
  ];
  if (d.reason) rows.push(["Reason", d.reason]);
  const sandboxNote = d.sandbox ? "Sandbox: this email was stored by the booking prototype and not sent." : "";

  const text = [
    `Hi ${d.attendeeName},`,
    "",
    intro,
    "",
    ...rows.map(([k, v]) => `${k}: ${v}`),
    ...(d.manageUrl && d.kind !== "cancellation" && d.kind !== "follow-up" ? ["", `Cancel or change it: ${d.manageUrl}`] : []),
    ...(sandboxNote ? ["", sandboxNote] : []),
  ].join("\n");

  const html = `<!doctype html><html><body style="margin:0;background:${escapeHtml(background)};color:${escapeHtml(textColor)};font-family:${escapeHtml(font)}">
<div style="max-width:560px;margin:0 auto;padding:24px">
<p>Hi ${escapeHtml(d.attendeeName)},</p>
<p>${escapeHtml(intro)}</p>
<table style="border-collapse:collapse">${rows.map(([k, v]) => `<tr><td style="padding:4px 12px 4px 0;font-weight:600">${escapeHtml(k)}</td><td style="padding:4px 0">${escapeHtml(v)}</td></tr>`).join("")}</table>
${d.manageUrl && d.kind !== "cancellation" && d.kind !== "follow-up" ? `<p><a href="${escapeHtml(d.manageUrl)}" style="color:${escapeHtml(primary)}">Cancel or change it</a></p>` : ""}
${sandboxNote ? `<p style="font-size:12px;opacity:.7">${escapeHtml(sandboxNote)}</p>` : ""}
</div></body></html>`;
  return { subject, html, text };
}
