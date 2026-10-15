// Stand-in for the template's `npm run build` in launcher tests, so they test
// the launcher's contract (BOOKING_OVERRIDES_DIR, dist/, the file cap) and not
// the booking pages themselves, which have their own tests.
// TEST_UI_FILES=<n> adds n extra files to dist/ to exercise the 100-file cap.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

mkdirSync("dist/assets", { recursive: true });
const ov = process.env.BOOKING_OVERRIDES_DIR;
const header = ov && existsSync(join(ov, "Header.tsx")) ? readFileSync(join(ov, "Header.tsx"), "utf8").trim() : "default header";
writeFileSync("dist/index.html", `<!doctype html><title>Booking</title><p>${header}</p>\n`);
writeFileSync("dist/assets/app.js", "console.log('booking');\n");
const extra = Number(process.env.TEST_UI_FILES || 0);
for (let i = 0; i < extra; i++) writeFileSync(`dist/assets/extra-${i}.js`, "\n");
