// Pure rules for the override layer, shared by the Vite plugin and the tests.
//
// A company can replace any named component of the booking pages by putting
// a file with the component's name in companies/{co}/booking/overrides/
// (for example overrides/Header.tsx), and can add whole pages under
// overrides/pages/ (overrides/pages/pricing.tsx becomes /pricing).

import { join, relative, sep } from "node:path";

/** Components the override layer can replace. Each lives in src/components/<Name>.tsx. */
export const SLOT_NAMES = [
  "Header",
  "EventList",
  "DurationPicker",
  "SlotPicker",
  "LocationPicker",
  "IntakeForm",
  "Confirmation",
  "RoutingForm",
  "Footer",
] as const;

export type SlotName = (typeof SLOT_NAMES)[number];

export const SLOT_PREFIX = "@slots/";
export const PAGES_MODULE = "virtual:booking-pages";

/** Routes the template already uses; an override page may not take them. */
export const RESERVED_ROUTES = ["/", "/owner", "/manage", "/l", "/route"];

export function isSlotName(name: string): name is SlotName {
  return (SLOT_NAMES as readonly string[]).includes(name);
}

export interface SlotResolution {
  path: string;
  override: boolean;
}

/**
 * Where `@slots/<name>` comes from: the company's override when the file
 * exists, else the template's component.
 */
export function resolveSlot(name: string, componentsDir: string, overridesDir: string | undefined, exists: (path: string) => boolean): SlotResolution {
  if (!isSlotName(name)) {
    throw new Error(`"@slots/${name}" is not a component the booking pages have. Use one of: ${SLOT_NAMES.join(", ")}.`);
  }
  if (overridesDir) {
    const candidate = join(overridesDir, `${name}.tsx`);
    if (exists(candidate)) return { path: candidate, override: true };
  }
  return { path: join(componentsDir, `${name}.tsx`), override: false };
}

/** overrides/pages/team/sales.tsx -> /team/sales; index.tsx -> the folder's path. Null for a bad name. */
export function routeFromPageFile(file: string): string | null {
  const parts = file.split(/[\\/]/);
  const last = parts.pop() ?? "";
  if (!/\.tsx$/.test(last)) return null;
  const base = last.replace(/\.tsx$/, "");
  const segments = [...parts, ...(base === "index" ? [] : [base])];
  if (!segments.every((s) => /^[a-z0-9][a-z0-9-]{0,62}$/.test(s))) return null;
  return `/${segments.join("/")}`;
}

export interface OverridePage {
  route: string;
  file: string;
}

export interface OverrideScan {
  slots: string[];
  pages: OverridePage[];
  errors: string[];
}

/**
 * Check the files in an overrides folder. `files` are paths relative to the
 * folder with forward or platform slashes. Every problem names the file.
 */
export function scanOverrides(files: string[], overridesDir: string): OverrideScan {
  const slots: string[] = [];
  const pages: OverridePage[] = [];
  const errors: string[] = [];
  const seenRoutes = new Map<string, string>();
  for (const raw of files.slice().sort()) {
    const file = raw.split(sep).join("/");
    const shown = join(overridesDir, file);
    if (file.startsWith(".") || file.includes("/.")) continue;
    if (file.startsWith("pages/")) {
      const rest = file.slice("pages/".length);
      if (!rest.endsWith(".tsx")) continue;
      const route = routeFromPageFile(rest);
      if (!route) {
        errors.push(`${shown}: page file names must be lowercase letters, digits and dashes (for example pages/pricing.tsx).`);
        continue;
      }
      if (RESERVED_ROUTES.some((r) => route === r || (r !== "/" && route.startsWith(`${r}/`)))) {
        errors.push(`${shown}: the route ${route} belongs to the booking pages. Pick another file name.`);
        continue;
      }
      const other = seenRoutes.get(route);
      if (other) {
        errors.push(`${shown}: the route ${route} is also made by ${join(overridesDir, other)}.`);
        continue;
      }
      seenRoutes.set(route, file);
      pages.push({ route, file: shown });
      continue;
    }
    if (file.includes("/")) continue; // helper folders an override may import from
    if (!file.endsWith(".tsx")) continue;
    const name = file.replace(/\.tsx$/, "");
    if (!isSlotName(name)) {
      // Lowercase files are helpers; capitalised ones look like a typo of a component name.
      if (/^[A-Z]/.test(name)) errors.push(`${shown}: there is no component called ${name}. Overridable components: ${SLOT_NAMES.join(", ")}.`);
      continue;
    }
    slots.push(name);
  }
  return { slots, pages, errors };
}

/** Source of the virtual module that lists the extra pages. */
export function pagesModuleSource(pages: OverridePage[]): string {
  const imports = pages.map((p, i) => `import Page${i} from ${JSON.stringify(p.file)};`);
  const list = pages.map((p, i) => `{ route: ${JSON.stringify(p.route)}, component: Page${i} }`);
  return `${imports.join("\n")}\nexport default [${list.join(", ")}];\n`;
}

/** A path for messages: relative to cwd when that is shorter. */
export function displayPath(path: string, cwd: string): string {
  const rel = relative(cwd, path);
  return rel && !rel.startsWith("..") && rel.length < path.length ? rel : path;
}
