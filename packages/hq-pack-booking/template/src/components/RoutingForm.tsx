import { useState } from "preact/hooks";
import { answersForApi } from "../lib/params.ts";
import { Button, describedBy, Field, Notice } from "../ui.tsx";
import type { RoutingFormProps } from "./types.ts";

/** A few questions that pick the right meeting. Answers carry on as intake answers. */
export default function RoutingForm({ form, onSubmit, busy, error, initial = {} }: RoutingFormProps) {
  const [values, setValues] = useState<Record<string, string | string[]>>(initial);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const submit = (e: Event) => {
    e.preventDefault();
    const missing: Record<string, string> = {};
    for (const q of form.questions) {
      const v = values[q.id];
      if (q.required && (v === undefined || (Array.isArray(v) ? v.length === 0 : v.trim() === ""))) missing[q.id] = "Please answer this.";
      if (q.type === "number" && typeof v === "string" && v.trim() && !/^-?\d+(\.\d+)?$/.test(v.trim())) missing[q.id] = "Enter a number.";
    }
    setErrors(missing);
    if (Object.keys(missing).length) {
      document.getElementById(`bk-r-${Object.keys(missing)[0]}`)?.focus();
      return;
    }
    onSubmit(answersForApi(form.questions, values));
  };
  return (
    <form class="bk-routing" onSubmit={submit} noValidate>
      {form.questions.map((q) => {
        const id = `bk-r-${q.id}`;
        const v = values[q.id];
        const text = Array.isArray(v) ? v.join(", ") : (v ?? "");
        const set = (nv: string | string[]) => setValues({ ...values, [q.id]: nv });
        if (q.type === "radio" || q.type === "checkbox") {
          const picked = Array.isArray(v) ? v : v ? [v] : [];
          return (
            <fieldset key={q.id} class={`bk-field bk-fieldset${errors[q.id] ? " bk-field-invalid" : ""}`}>
              <legend class="bk-label">{q.label}</legend>
              <div class="bk-option-list">
                {(q.options ?? []).map((o, i) => (
                  <label key={o} class="bk-option">
                    <input
                      id={i === 0 ? id : undefined}
                      type={q.type}
                      name={id}
                      checked={picked.includes(o)}
                      onChange={(e) => (q.type === "radio" ? set(o) : set((e.currentTarget as HTMLInputElement).checked ? [...picked, o] : picked.filter((p) => p !== o)))}
                    />
                    <span>{o}</span>
                  </label>
                ))}
              </div>
              {errors[q.id] && <p class="bk-field-error">{errors[q.id]}</p>}
            </fieldset>
          );
        }
        return (
          <Field key={q.id} id={id} label={q.label} required={q.required} error={errors[q.id]}>
            {q.type === "select" ? (
              <select id={id} class="bk-input" value={text} onChange={(e) => set((e.currentTarget as HTMLSelectElement).value)} aria-invalid={errors[q.id] ? "true" : undefined} aria-describedby={describedBy(id, undefined, errors[q.id])}>
                <option value="">Choose…</option>
                {(q.options ?? []).map((o) => (
                  <option key={o}>{o}</option>
                ))}
              </select>
            ) : q.type === "textarea" ? (
              <textarea id={id} class="bk-input bk-textarea" rows={3} value={text} onInput={(e) => set((e.currentTarget as HTMLTextAreaElement).value)} aria-invalid={errors[q.id] ? "true" : undefined} aria-describedby={describedBy(id, undefined, errors[q.id])} />
            ) : (
              <input
                id={id}
                class="bk-input"
                type={q.type === "number" ? "text" : q.type === "email" ? "email" : q.type === "phone" ? "tel" : "text"}
                inputMode={q.type === "number" ? "numeric" : undefined}
                value={text}
                onInput={(e) => set((e.currentTarget as HTMLInputElement).value)}
                aria-invalid={errors[q.id] ? "true" : undefined}
                aria-describedby={describedBy(id, undefined, errors[q.id])}
              />
            )}
          </Field>
        );
      })}
      {error && (
        <Notice tone="danger" live>
          {error}
        </Notice>
      )}
      <Button type="submit" variant="primary" busy={busy}>
        {busy ? "Finding the right meeting…" : "Continue"}
      </Button>
    </form>
  );
}
