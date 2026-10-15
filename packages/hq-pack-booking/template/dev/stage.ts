// Stage a deployable copy of the app for hq-deploy's `app` deploy type.
//
//   node --experimental-strip-types dev/stage.ts <booking.yaml> <out-dir> [--dist <built-ui-dir>]
//
// hq-deploy uploads only the build output (dist/), api/ and db/migrations/,
// installs no npm packages and bundles api/ with esbuild. So the stage:
// - checks booking.yaml and writes it as api/_lib/booking.config.json,
// - copies api/ without tests, and the dependency-free engine modules from
//   shared/ into api/_lib/shared/ (engine.ts is rewritten to point there),
// - copies db/migrations/ and the built UI,
// - checks the result: every import stays inside api/, the only packages are
//   node:* and @hq/db, and the upload stays under hq-deploy's 100-file cap.
// Then run the /deploy skill from <out-dir> (output dir dist, api dir api).

import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { checkBookingYaml } from "../shared/config.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const ENGINE_MODULES = ["availability.ts", "assignment.ts", "time.ts"];
export const MAX_FILES = 100;

function walk(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
}

export interface StageResult {
  ok: boolean;
  out: string;
  files: number;
  problems: string[];
}

/** Check a staged directory. Returns plain problems; empty means deployable. */
export function checkStaged(out: string): string[] {
  const problems: string[] = [];
  const apiDir = join(out, "api");
  const files = walk(apiDir).concat(walk(join(out, "db", "migrations")), walk(join(out, "dist")));
  if (files.length > MAX_FILES) problems.push(`${files.length} files; hq-deploy accepts at most ${MAX_FILES}.`);
  for (const file of walk(apiDir).filter((f) => f.endsWith(".ts"))) {
    if (/\.test\.ts$/.test(file)) problems.push(`${relative(out, file)} is a test file.`);
    const src = readFileSync(file, "utf8");
    for (const m of src.matchAll(/^\s*(import|export)\s+(type\s+)?[^;]*?from\s+["']([^"']+)["']/gm)) {
      const typeOnly = !!m[2];
      const spec = m[3] as string;
      if (spec.startsWith(".")) {
        const target = resolve(dirname(file), spec);
        if (!target.startsWith(apiDir + sep)) problems.push(`${relative(out, file)} imports ${spec}, outside api/.`);
        else if (!typeOnly && !existsSync(target)) problems.push(`${relative(out, file)} imports ${spec}, which is missing.`);
      } else if (!typeOnly && !spec.startsWith("node:") && spec !== "@hq/db") {
        problems.push(`${relative(out, file)} imports the package ${spec}; hq-deploy installs no packages.`);
      }
    }
  }
  const handlers = walk(apiDir).filter((f) => f.endsWith(".ts") && !f.includes(`${sep}_lib${sep}`));
  for (const h of handlers) {
    if (!/export default /.test(readFileSync(h, "utf8"))) problems.push(`${relative(out, h)} has no default export handler.`);
  }
  return problems;
}

export function stage(configPath: string, out: string, distDir?: string): StageResult {
  const checked = checkBookingYaml(readFileSync(configPath, "utf8"));
  if (!checked.ok || !checked.config) {
    return { ok: false, out, files: 0, problems: checked.errors.map((e) => `${configPath} ${e.path}: ${e.message}`) };
  }
  if (existsSync(out) && readdirSync(out).length > 0) return { ok: false, out, files: 0, problems: [`${out} is not empty.`] };
  mkdirSync(out, { recursive: true });
  cpSync(join(root, "api"), join(out, "api"), { recursive: true, filter: (src) => !src.endsWith(".test.ts") });
  writeFileSync(join(out, "api", "_lib", "booking.config.json"), `${JSON.stringify(checked.config, null, 2)}\n`);
  mkdirSync(join(out, "api", "_lib", "shared"), { recursive: true });
  for (const m of ENGINE_MODULES) cpSync(join(root, "shared", m), join(out, "api", "_lib", "shared", m));
  const engine = join(out, "api", "_lib", "engine.ts");
  writeFileSync(engine, readFileSync(engine, "utf8").replaceAll('"../../shared/', '"./shared/'));
  cpSync(join(root, "db", "migrations"), join(out, "db", "migrations"), { recursive: true });
  const dist = distDir ?? join(root, "dist");
  if (existsSync(dist)) cpSync(dist, join(out, "dist"), { recursive: true });
  const problems = checkStaged(out);
  const files = walk(join(out, "api")).length + walk(join(out, "db")).length + walk(join(out, "dist")).length;
  return { ok: problems.length === 0, out, files, problems };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [configPath, out] = process.argv.slice(2);
  const i = process.argv.indexOf("--dist");
  if (!configPath || !out) {
    console.log(JSON.stringify({ ok: false, error: "usage", message: "Use: stage.ts <booking.yaml> <out-dir> [--dist <dir>]" }));
    process.exit(2);
  }
  const result = stage(resolve(configPath), resolve(out), i > 0 ? resolve(process.argv[i + 1] as string) : undefined);
  console.log(JSON.stringify(result));
  process.exit(result.ok ? 0 : 1);
}
