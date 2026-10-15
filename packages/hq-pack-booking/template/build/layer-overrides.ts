// Vite plugin that layers a company's overrides over the template.
//
//   BOOKING_OVERRIDES_DIR=/path/to/companies/{co}/booking/overrides npm run build
//
// `@slots/<Name>` imports resolve to <overrides>/<Name>.tsx when that file
// exists and to src/components/<Name>.tsx otherwise. Files under
// <overrides>/pages/ become extra routes through `virtual:booking-pages`.
// Every build problem in an override names the override file; a broken
// override fails the build instead of falling back to the template.

import { existsSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { transformWithEsbuild, type Plugin } from "vite";
import { displayPath, PAGES_MODULE, pagesModuleSource, resolveSlot, scanOverrides, SLOT_PREFIX, type OverrideScan } from "./overrides-core.ts";

const RESOLVED_PAGES = `\0${PAGES_MODULE}`;

function listFiles(dir: string, base = ""): string[] {
  const out: string[] = [];
  for (const name of readdirSync(join(dir, base))) {
    const rel = base ? `${base}/${name}` : name;
    if (statSync(join(dir, rel)).isDirectory()) out.push(...listFiles(dir, rel));
    else out.push(rel);
  }
  return out;
}

export function layerOverrides(opts: { componentsDir: string; overridesDir?: string }): Plugin {
  const overridesDir = opts.overridesDir ? resolve(opts.overridesDir) : undefined;
  const cwd = process.cwd();
  let scan: OverrideScan = { slots: [], pages: [], errors: [] };
  const inOverrides = (id: string) => !!overridesDir && id.startsWith(`${overridesDir}/`);

  return {
    name: "hq-booking-overrides",
    enforce: "pre",

    config() {
      return overridesDir ? { server: { fs: { allow: [overridesDir] } } } : undefined;
    },

    buildStart() {
      if (!overridesDir) return;
      if (!existsSync(overridesDir) || !statSync(overridesDir).isDirectory()) {
        this.error(`BOOKING_OVERRIDES_DIR is ${overridesDir}, which is not a folder. Create it or unset the variable.`);
      }
      scan = scanOverrides(listFiles(overridesDir), overridesDir);
      if (scan.errors.length) this.error(`Booking overrides have problems:\n${scan.errors.map((e) => `  ${e}`).join("\n")}`);
      this.addWatchFile(overridesDir);
      const used = scan.slots.length ? scan.slots.join(", ") : "none";
      this.info?.(`booking overrides from ${displayPath(overridesDir, cwd)}: components ${used}; pages ${scan.pages.map((p) => p.route).join(", ") || "none"}`);
    },

    resolveId(source) {
      if (source === PAGES_MODULE) return RESOLVED_PAGES;
      if (!source.startsWith(SLOT_PREFIX)) return null;
      try {
        return resolveSlot(source.slice(SLOT_PREFIX.length), opts.componentsDir, overridesDir, existsSync).path;
      } catch (e) {
        this.error((e as Error).message);
      }
    },

    load(id) {
      if (id === RESOLVED_PAGES) return pagesModuleSource(scan.pages);
      return null;
    },

    async transform(code, id) {
      if (!inOverrides(id) || !/\.(tsx?|jsx?)$/.test(id)) return null;
      try {
        const out = await transformWithEsbuild(code, id, { loader: id.endsWith("x") ? "tsx" : "ts", jsx: "automatic", jsxImportSource: "preact", target: "es2020" });
        return { code: out.code, map: out.map ? JSON.stringify(out.map) : null };
      } catch (e) {
        const err = e as { errors?: { text: string; location?: { line: number; column: number } | null }[]; message: string };
        const first = err.errors?.[0];
        const where = first?.location ? `:${first.location.line}:${first.location.column}` : "";
        this.error(`Override ${displayPath(id, cwd)}${where} failed to build: ${first?.text ?? err.message}`);
      }
    },
  };
}
