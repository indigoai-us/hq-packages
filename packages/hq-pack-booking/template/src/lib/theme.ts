// booking.yaml theme -> CSS custom properties. Every color, font and radius
// the pages use comes from these variables. Pure, so node --test runs it.

import type { Theme } from "./types.ts";

export const DEFAULT_THEME = {
  primary: "#1b1b1a",
  background: "#ffffff",
  surface: "#f6f6f4",
  text: "#1b1b1a",
  muted: "#63635f",
  accent: "#1b1b1a",
  heading: '"Iowan Old Style", "Palatino Linotype", Palatino, "Book Antiqua", Charter, Georgia, serif',
  body: 'ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue", Arial, sans-serif',
  radius: 10,
};

const SEMANTIC = { danger: "#b42318", success: "#17663f", warning: "#8a5a00" };

type Rgb = [number, number, number];

export function parseHex(hex: string): Rgb | null {
  const m = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  let h = m[1] as string;
  if (h.length === 3) h = h.split("").map((c) => c + c).join("");
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
}

export function toHex([r, g, b]: Rgb): string {
  return `#${[r, g, b].map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0")).join("")}`;
}

/** a mixed toward b by t (0..1). */
export function mix(a: string, b: string, t: number): string {
  const x = parseHex(a);
  const y = parseHex(b);
  if (!x || !y) return a;
  return toHex([x[0] + (y[0] - x[0]) * t, x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t]);
}

function channel(v: number): number {
  const s = v / 255;
  return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

export function luminance(hex: string): number {
  const c = parseHex(hex);
  if (!c) return 0;
  return 0.2126 * channel(c[0]) + 0.7152 * channel(c[1]) + 0.0722 * channel(c[2]);
}

export function contrast(a: string, b: string): number {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** Move fg toward black or white (whichever contrasts with bg) until it reaches the ratio. */
export function ensureContrast(fg: string, bg: string, ratio = 4.5): string {
  if (contrast(fg, bg) >= ratio) return fg;
  const target = luminance(bg) > 0.4 ? "#000000" : "#ffffff";
  for (let t = 0.05; t <= 1; t += 0.05) {
    const c = mix(fg, target, t);
    if (contrast(c, bg) >= ratio) return c;
  }
  return target;
}

/** Text color on a filled background: whichever of white or near-black reads better. */
export function onColor(bg: string): string {
  return contrast("#ffffff", bg) >= contrast("#111111", bg) ? "#ffffff" : "#111111";
}

const GENERIC_FONTS = new Set(["serif", "sans-serif", "monospace", "system-ui", "ui-sans-serif", "ui-serif", "cursive"]);

function fontName(raw: string | undefined): string | null {
  if (!raw) return null;
  const name = raw.trim();
  if (!/^[A-Za-z0-9 ]{2,60}$/.test(name)) return null;
  return name;
}

/** A Google Fonts stylesheet for named theme fonts, or null when the theme names none. */
export function fontStylesheet(theme: Theme): string | null {
  const names = [fontName(theme.fonts?.heading), fontName(theme.fonts?.body)].filter((n): n is string => !!n && !GENERIC_FONTS.has(n.toLowerCase()));
  const unique = [...new Set(names)];
  if (!unique.length) return null;
  const families = unique.map((n) => `family=${n.replace(/ /g, "+")}:wght@400;500`).join("&");
  return `https://fonts.googleapis.com/css2?${families}&display=swap`;
}

function color(v: string | undefined, fallback: string): string {
  return v && parseHex(v) ? toHex(parseHex(v) as Rgb) : fallback;
}

/** CSS variables for a theme. Missing or invalid values use the neutral default. */
export function themeVars(theme: Theme = {}): Record<string, string> {
  const c = theme.colors ?? {};
  const bg = color(c.background, DEFAULT_THEME.background);
  const dark = luminance(bg) < 0.3;
  const text = ensureContrast(color(c.text, dark ? "#f4f4f2" : DEFAULT_THEME.text), bg, 7);
  const surface = color(c.surface, c.background ? mix(bg, text, 0.035) : DEFAULT_THEME.surface);
  const muted = ensureContrast(color(c.muted, c.text || c.background ? mix(text, bg, 0.38) : DEFAULT_THEME.muted), bg, 4.6);
  const primary = color(c.primary, c.text ? text : DEFAULT_THEME.primary);
  const accent = color(c.accent, primary);
  const heading = fontName(theme.fonts?.heading);
  const body = fontName(theme.fonts?.body);
  const radius = typeof theme.radius === "number" && theme.radius >= 0 && theme.radius <= 32 ? Math.round(theme.radius) : DEFAULT_THEME.radius;
  return {
    "--bk-bg": bg,
    "--bk-surface": surface,
    "--bk-text": text,
    "--bk-muted": muted,
    "--bk-primary": primary,
    "--bk-on-primary": onColor(primary),
    // Primary used as text (links, selected outlines) must still read on the background.
    "--bk-primary-text": ensureContrast(primary, bg, 4.5),
    "--bk-primary-soft": mix(bg, primary, 0.08),
    "--bk-accent": accent,
    "--bk-border": mix(bg, text, 0.12),
    "--bk-border-strong": mix(bg, text, 0.28),
    "--bk-hover": mix(bg, text, 0.05),
    "--bk-focus": ensureContrast(primary, bg, 3),
    "--bk-danger": ensureContrast(SEMANTIC.danger, bg, 4.5),
    "--bk-danger-soft": mix(bg, SEMANTIC.danger, 0.08),
    "--bk-success": ensureContrast(SEMANTIC.success, bg, 4.5),
    "--bk-success-soft": mix(bg, SEMANTIC.success, 0.08),
    "--bk-warning": ensureContrast(SEMANTIC.warning, bg, 4.5),
    "--bk-warning-soft": mix(bg, SEMANTIC.warning, 0.08),
    "--bk-font-heading": heading && !GENERIC_FONTS.has(heading.toLowerCase()) ? `"${heading}", ${DEFAULT_THEME.heading}` : DEFAULT_THEME.heading,
    "--bk-font-body": body && !GENERIC_FONTS.has(body.toLowerCase()) ? `"${body}", ${DEFAULT_THEME.body}` : DEFAULT_THEME.body,
    "--bk-radius": `${radius}px`,
    "--bk-radius-sm": `${Math.max(0, Math.round(radius * 0.6))}px`,
    "--bk-radius-lg": `${Math.round(radius * 1.4)}px`,
    "--bk-scheme": dark ? "dark" : "light",
  };
}

/** Only http(s) or same-origin paths for logo and image URLs. */
export function safeAssetUrl(url: string | undefined): string | null {
  if (!url) return null;
  if (url.startsWith("/") && !url.startsWith("//")) return url;
  try {
    const u = new URL(url);
    return u.protocol === "https:" || u.protocol === "http:" ? u.href : null;
  } catch {
    return null;
  }
}
