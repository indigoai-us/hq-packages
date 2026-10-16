// App-wide state: the public config and the visitor's display choices.

import { createContext } from "preact";
import { useContext } from "preact/hooks";
import type { EmbedParams } from "./lib/params.ts";
import type { PublicConfig } from "./lib/types.ts";

export interface AppState {
  config: PublicConfig;
  embed: EmbedParams;
  /** The visitor's time zone (auto-detected, changeable). */
  timezone: string;
  setTimezone: (tz: string) => void;
  hour12: boolean;
  setHour12: (v: boolean) => void;
}

export const AppContext = createContext<AppState | null>(null);

export function useApp(): AppState {
  const v = useContext(AppContext);
  if (!v) throw new Error("AppContext missing");
  return v;
}

/** Tell the embedding page (if any) something happened. */
export function postToParent(state: AppState, message: Record<string, unknown>): void {
  if (!state.embed.embedded || window.parent === window) return;
  const target = state.embed.origin ?? "*";
  try {
    window.parent.postMessage(message, target);
  } catch {
    /* parent gone */
  }
}
