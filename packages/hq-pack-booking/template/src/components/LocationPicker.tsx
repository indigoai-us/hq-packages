import { locationDetail, locationTitle } from "../lib/labels.ts";
import { describedBy, Field, Icon } from "../ui.tsx";
import type { LocationPickerProps } from "./types.ts";

function iconFor(type: string): string {
  if (type === "phone") return "phone";
  if (type === "in-person") return "pin";
  if (type === "custom") return "link";
  return "video";
}

/** Where the meeting happens. A single location is shown, not asked. */
export default function LocationPicker({ locations, value, onChange, phone, onPhoneChange, error }: LocationPickerProps) {
  const current = locations[value];
  const needsPhone = current?.type === "phone" && current.caller === "host";
  return (
    <fieldset class="bk-fieldset">
      <legend class="bk-label">Location</legend>
      <div class="bk-choices">
        {locations.map((l, i) => (
          <label key={l.type} class={`bk-choice${i === value ? " is-selected" : ""}`}>
            <input type="radio" name="bk-location" checked={i === value} onChange={() => onChange(i)} class="bk-sr-input" disabled={locations.length === 1} />
            <span class="bk-choice-icon">
              <Icon name={iconFor(l.type)} size={18} />
            </span>
            <span class="bk-choice-text">
              <span class="bk-choice-title">{locationTitle(l)}</span>
              <span class="bk-choice-detail">{locationDetail(l)}</span>
            </span>
          </label>
        ))}
      </div>
      {needsPhone && (
        <Field id="bk-phone" label="Your phone number" required error={error}>
          <input
            id="bk-phone"
            type="tel"
            autocomplete="tel"
            class="bk-input"
            value={phone}
            onInput={(e) => onPhoneChange((e.currentTarget as HTMLInputElement).value)}
            aria-invalid={error ? "true" : undefined}
            aria-describedby={describedBy("bk-phone", undefined, error)}
            required
          />
        </Field>
      )}
    </fieldset>
  );
}
