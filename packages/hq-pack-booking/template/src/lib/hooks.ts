import { useCallback, useEffect, useRef, useState } from "preact/hooks";
import { errorMessage } from "./api.ts";

export interface Async<T> {
  data: T | undefined;
  error: string | null;
  loading: boolean;
  reload: () => void;
  set: (v: T) => void;
}

/** Load data; keeps the previous data while reloading so lists don't jump. */
export function useAsync<T>(fn: (signal: AbortSignal) => Promise<T>, deps: unknown[]): Async<T> {
  const [data, setData] = useState<T | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    const ctl = new AbortController();
    setLoading(true);
    setError(null);
    fn(ctl.signal)
      .then((v) => {
        if (!ctl.signal.aborted) {
          setData(v);
          setLoading(false);
        }
      })
      .catch((e) => {
        if (ctl.signal.aborted || (e as Error).name === "AbortError") return;
        setError(errorMessage(e));
        setLoading(false);
      });
    return () => ctl.abort();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  const reload = useCallback(() => setTick((t) => t + 1), []);
  return { data, error, loading, reload, set: setData };
}

/** Current time, updated every `ms`. */
export function useNow(ms = 1000): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

/** Run an action with busy and error state. */
export function useAction<A extends unknown[], R>(fn: (...args: A) => Promise<R>) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const live = useRef(true);
  useEffect(() => () => void (live.current = false), []);
  const run = useCallback(
    async (...args: A): Promise<R | undefined> => {
      setBusy(true);
      setError(null);
      try {
        return await fn(...args);
      } catch (e) {
        if (live.current) setError(errorMessage(e));
        return undefined;
      } finally {
        if (live.current) setBusy(false);
      }
    },
    [fn],
  );
  return { run, busy, error, setError };
}

/** A value kept in localStorage (preferences only, nothing personal). */
export function useStored<T extends string>(key: string, initial: T): [T, (v: T) => void] {
  const [v, setV] = useState<T>(() => {
    try {
      return (localStorage.getItem(key) as T | null) ?? initial;
    } catch {
      return initial;
    }
  });
  const set = useCallback(
    (nv: T) => {
      setV(nv);
      try {
        localStorage.setItem(key, nv);
      } catch {
        /* storage off */
      }
    },
    [key],
  );
  return [v, set];
}
