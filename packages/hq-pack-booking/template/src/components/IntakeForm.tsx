import { useState } from "preact/hooks";
import type { Question } from "../lib/types.ts";
import { describedBy, Field } from "../ui.tsx";
import type { IntakeFormProps } from "./types.ts";

function QuestionInput({ q, value, onChange, error, disabled }: { q: Question; value: string | string[] | undefined; onChange: (v: string | string[]) => void; error?: string; disabled?: boolean }) {
  const id = `bk-q-${q.id}`;
  const common = {
    id,
    disabled,
    "aria-invalid": error ? ("true" as const) : undefined,
    "aria-describedby": describedBy(id, undefined, error),
    required: q.required,
  };
  const text = Array.isArray(value) ? value.join(", ") : (value ?? "");
  if (q.type === "textarea") {
    return <textarea {...common} class="bk-input bk-textarea" rows={4} maxLength={q.maxLength ?? 2000} value={text} onInput={(e) => onChange((e.currentTarget as HTMLTextAreaElement).value)} />;
  }
  if (q.type === "select") {
    return (
      <select {...common} class="bk-input" value={text} onChange={(e) => onChange((e.currentTarget as HTMLSelectElement).value)}>
        <option value="">Choose…</option>
        {(q.options ?? []).map((o) => (
          <option key={o} value={o}>
            {o}
          </option>
        ))}
      </select>
    );
  }
  if (q.type === "radio" || q.type === "checkbox") {
    const picked = Array.isArray(value) ? value : value ? [value] : [];
    return (
      <div class="bk-option-list" role={q.type === "radio" ? "radiogroup" : "group"} aria-labelledby={`${id}-legend`} aria-describedby={describedBy(id, undefined, error)}>
        {(q.options ?? []).map((o) => (
          <label key={o} class="bk-option">
            <input
              type={q.type}
              name={id}
              value={o}
              disabled={disabled}
              checked={picked.includes(o)}
              onChange={(e) => {
                const on = (e.currentTarget as HTMLInputElement).checked;
                if (q.type === "radio") onChange(o);
                else onChange(on ? [...picked, o] : picked.filter((p) => p !== o));
              }}
            />
            <span>{o}</span>
          </label>
        ))}
      </div>
    );
  }
  const type = q.type === "email" ? "email" : q.type === "phone" ? "tel" : q.type === "number" ? "number" : "text";
  return <input {...common} class="bk-input" type={type} inputMode={q.type === "number" ? "numeric" : undefined} maxLength={q.maxLength ?? 500} value={text} onInput={(e) => onChange((e.currentTarget as HTMLInputElement).value)} />;
}

/** Name, email, the event type's questions and optional guests. */
export default function IntakeForm({ eventType, values, onChange, errors, disabled }: IntakeFormProps) {
  const [showGuests, setShowGuests] = useState(values.guests.trim() !== "");
  const set = (patch: Partial<typeof values>) => onChange({ ...values, ...patch });
  return (
    <div class="bk-intake">
      <Field id="bk-name" label="Your name" required error={errors.name}>
        <input
          id="bk-name"
          class="bk-input"
          autocomplete="name"
          value={values.name}
          disabled={disabled}
          required
          maxLength={200}
          aria-invalid={errors.name ? "true" : undefined}
          aria-describedby={describedBy("bk-name", undefined, errors.name)}
          onInput={(e) => set({ name: (e.currentTarget as HTMLInputElement).value })}
        />
      </Field>
      <Field id="bk-email" label="Email" required error={errors.email}>
        <input
          id="bk-email"
          class="bk-input"
          type="email"
          autocomplete="email"
          value={values.email}
          disabled={disabled}
          required
          maxLength={254}
          aria-invalid={errors.email ? "true" : undefined}
          aria-describedby={describedBy("bk-email", undefined, errors.email)}
          onInput={(e) => set({ email: (e.currentTarget as HTMLInputElement).value })}
        />
      </Field>
      {eventType.questions.map((q) =>
        q.type === "radio" || q.type === "checkbox" ? (
          <fieldset key={q.id} class={`bk-field bk-fieldset${errors[q.id] ? " bk-field-invalid" : ""}`}>
            <legend class="bk-label" id={`bk-q-${q.id}-legend`}>
              {q.label}
              {q.required ? <span class="bk-required"> (required)</span> : null}
            </legend>
            <QuestionInput q={q} value={values.answers[q.id]} disabled={disabled} error={errors[q.id]} onChange={(v) => set({ answers: { ...values.answers, [q.id]: v } })} />
            {errors[q.id] && (
              <p class="bk-field-error" id={`bk-q-${q.id}-error`}>
                {errors[q.id]}
              </p>
            )}
          </fieldset>
        ) : (
          <Field key={q.id} id={`bk-q-${q.id}`} label={q.label} required={q.required} error={errors[q.id]}>
            <QuestionInput q={q} value={values.answers[q.id]} disabled={disabled} error={errors[q.id]} onChange={(v) => set({ answers: { ...values.answers, [q.id]: v } })} />
          </Field>
        ),
      )}
      {eventType.guestsMax > 0 &&
        (showGuests ? (
          <Field id="bk-guests" label="Guests" hint={`Up to ${eventType.guestsMax} email${eventType.guestsMax === 1 ? "" : "s"}, separated by commas. They get the invite too.`} error={errors.guests}>
            <textarea
              id="bk-guests"
              class="bk-input bk-textarea"
              rows={2}
              value={values.guests}
              disabled={disabled}
              aria-invalid={errors.guests ? "true" : undefined}
              aria-describedby={describedBy("bk-guests", "hint", errors.guests)}
              onInput={(e) => set({ guests: (e.currentTarget as HTMLTextAreaElement).value })}
            />
          </Field>
        ) : (
          <button type="button" class="bk-textlink bk-add-guests" onClick={() => setShowGuests(true)}>
            Add guests
          </button>
        ))}
    </div>
  );
}
