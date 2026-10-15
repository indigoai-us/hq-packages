// Routing forms: answers in, one target out (an event type, optionally some
// of its hosts, or an outside URL). Rules are checked in order; the first
// match wins, otherwise the form's default.

import { checkAnswers } from "./bookings.ts";
import type { RoutingForm, RoutingTarget } from "./engine.ts";

export function evaluateRouting(form: RoutingForm, rawAnswers: unknown): { target: RoutingTarget; rule: number | null } {
  const answers = checkAnswers(form.questions, rawAnswers);
  for (let i = 0; i < form.rules.length; i++) {
    const { when, to } = form.rules[i] as RoutingForm["rules"][number];
    const v = answers[when.question];
    if (v === undefined) continue;
    const values = Array.isArray(v) ? v.map(String) : [String(v)];
    let ok = true;
    if (when.equals !== undefined) ok = ok && values.some((x) => x.toLowerCase() === (when.equals as string).toLowerCase());
    if (when.in !== undefined) ok = ok && values.some((x) => (when.in as string[]).some((y) => y.toLowerCase() === x.toLowerCase()));
    if (when.gte !== undefined || when.lte !== undefined) {
      const n = typeof v === "number" ? v : Number(values[0]);
      ok = ok && Number.isFinite(n) && (when.gte === undefined || n >= when.gte) && (when.lte === undefined || n <= when.lte);
    }
    if (ok) return { target: to, rule: i };
  }
  return { target: form.default, rule: null };
}
