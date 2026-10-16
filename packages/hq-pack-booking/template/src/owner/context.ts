import { createContext } from "preact";
import { useContext } from "preact/hooks";
import type { OwnerSession } from "../lib/types.ts";

export interface OwnerState {
  session: OwnerSession;
  call: <T>(path: string, opts?: { method?: string; body?: unknown }) => Promise<T>;
}

export const OwnerContext = createContext<OwnerState | null>(null);

export function useOwner(): OwnerState {
  const v = useContext(OwnerContext);
  if (!v) throw new Error("OwnerContext missing");
  return v;
}

/** The owner's own zone for dashboard times. */
export const ownerZone = (): string => Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
