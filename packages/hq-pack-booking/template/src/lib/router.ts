// A small history router. hq-deploy serves index.html for unknown paths,
// so every route is client-side.

import { useEffect, useState } from "preact/hooks";

type Listener = () => void;
const listeners = new Set<Listener>();

function emit() {
  for (const l of listeners) l();
}

if (typeof window !== "undefined") window.addEventListener("popstate", emit);

export function navigate(to: string, opts: { replace?: boolean } = {}): void {
  if (opts.replace) history.replaceState(null, "", to);
  else history.pushState(null, "", to);
  window.scrollTo({ top: 0 });
  emit();
}

export interface Location {
  path: string;
  search: string;
  query: URLSearchParams;
}

function current(): Location {
  return { path: location.pathname.replace(/\/+$/, "") || "/", search: location.search, query: new URLSearchParams(location.search) };
}

export function useLocation(): Location {
  const [loc, setLoc] = useState(current);
  useEffect(() => {
    const l = () => setLoc(current());
    listeners.add(l);
    return () => void listeners.delete(l);
  }, []);
  return loc;
}

/** Match "/manage/:id" against a path; returns params or null. */
export function match(pattern: string, path: string): Record<string, string> | null {
  const p = pattern.split("/").filter(Boolean);
  const s = path.split("/").filter(Boolean);
  if (p.length !== s.length) return null;
  const out: Record<string, string> = {};
  for (let i = 0; i < p.length; i++) {
    const part = p[i] as string;
    const seg = s[i] as string;
    if (part.startsWith(":")) {
      try {
        out[part.slice(1)] = decodeURIComponent(seg);
      } catch {
        return null;
      }
    } else if (part !== seg) return null;
  }
  return out;
}

/** onClick for <a href> that routes in-app (keeps modifier-click behavior). */
export function linkClick(e: MouseEvent): void {
  const a = e.currentTarget as HTMLAnchorElement;
  if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || a.target === "_blank") return;
  if (a.origin !== location.origin) return;
  e.preventDefault();
  navigate(a.pathname + a.search + a.hash);
}
