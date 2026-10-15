import { formatDuration } from "../lib/time.ts";
import { Segmented } from "../ui.tsx";
import type { DurationPickerProps } from "./types.ts";

/** Choose a meeting length when the event type offers more than one. */
export default function DurationPicker({ durations, value, onChange }: DurationPickerProps) {
  if (durations.length < 2) return null;
  return (
    <div class="bk-duration">
      <span class="bk-mini-label" id="bk-duration-label">
        Length
      </span>
      <Segmented
        label="Meeting length"
        value={String(value)}
        options={durations.map((d) => ({ value: String(d), label: formatDuration(d) }))}
        onChange={(v) => onChange(Number(v))}
      />
    </div>
  );
}
