#!/usr/bin/env node
/**
 * acct-import — turn a bank / QuickBooks CSV export into balanced double-entry
 * journal-entry markdown files for the HQ ontology.
 *
 * Each statement row becomes ONE balanced two-line journal entry:
 *   - one leg is the bank/clearing account the statement is FOR (known up front),
 *   - the other leg is the category account resolved from the row via the
 *     company's account-map.json.
 * The two legs carry equal amounts on opposite sides, so every produced entry is
 * balanced BY CONSTRUCTION (and asserted — `assertBalanced`). Unmapped rows are
 * surfaced for review and NOT posted, unless `--post-mapped-only` routes their
 * category leg to the Suspense account (and flags them).
 *
 * Re-import is idempotent: each entry's id is a deterministic sha256 of a stable
 * canonical name derived from the row's transaction id (or a hash of
 * date|description|amount), so the same export always yields the same entities.
 *
 * Pure core (parseCsv / resolveAccount / buildEntryForRow / runImport /
 * serializeEntryMarkdown) is exported for tests; only `main` touches the disk.
 *
 * Dependencies: node built-ins only (no install needed).
 */

import { createHash } from "node:crypto";
import {
  readFileSync,
  writeFileSync,
  mkdirSync,
  existsSync,
} from "node:fs";
import { join } from "node:path";

// ── Deterministic ids (must match hq-pro generateEntityId) ───────────────

/** sha256(`${type}:${canonicalName}`) — identical to hq-pro's generateEntityId. */
export function entityId(type, canonicalName) {
  return createHash("sha256").update(`${type}:${canonicalName}`).digest("hex");
}

/** "Operating Checking" → "operating-checking" (matches hq-pro toSlug). */
export function slugify(name) {
  return String(name)
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function accountRefFor(name) {
  return `../account/${slugify(name)}.md`;
}

// ── CSV parsing (RFC-4180-ish: quotes + embedded commas) ──────────────────

export function parseCsv(text) {
  const rows = [];
  let field = "";
  let record = [];
  let inQuotes = false;
  const pushField = () => {
    record.push(field);
    field = "";
  };
  const pushRecord = () => {
    pushField();
    rows.push(record);
    record = [];
  };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else inQuotes = false;
      } else field += c;
    } else if (c === '"') inQuotes = true;
    else if (c === ",") pushField();
    else if (c === "\n") pushRecord();
    else if (c === "\r") {
      /* skip */
    } else field += c;
  }
  if (field.length > 0 || record.length > 0) pushRecord();
  if (rows.length === 0) return [];
  const header = rows[0].map((h) => h.trim().toLowerCase());
  return rows.slice(1).filter((r) => r.some((v) => v.trim() !== "")).map((r) => {
    const obj = {};
    header.forEach((h, idx) => (obj[h] = (r[idx] ?? "").trim()));
    return obj;
  });
}

/** Parse a money string ("$1,234.56", "(45.00)") to a signed Number. */
export function parseAmount(raw) {
  if (raw == null) return NaN;
  let s = String(raw).trim();
  let sign = 1;
  if (/^\(.*\)$/.test(s)) {
    sign = -1;
    s = s.slice(1, -1);
  }
  s = s.replace(/[$,\s]/g, "");
  if (s.startsWith("-")) {
    sign *= -1;
    s = s.slice(1);
  }
  const n = Number(s);
  return Number.isFinite(n) ? sign * n : NaN;
}

/** Signed amount for a row: prefer `amount`, else credit - debit. */
export function rowAmount(row) {
  if (row.amount !== undefined && row.amount !== "") return parseAmount(row.amount);
  const credit = row.credit ? parseAmount(row.credit) : 0;
  const debit = row.debit ? parseAmount(row.debit) : 0;
  return (credit || 0) - (debit || 0);
}

/** Stable per-row key for idempotent ids + the quickbooks external id. */
export function rowKey(row) {
  return (
    row["transaction id"] ||
    row["transaction_id"] ||
    row.txnid ||
    row.ref ||
    row.id ||
    ""
  );
}

// ── Account resolution (the account-map.json contract) ────────────────────

/**
 * Resolve a row's category account NAME from the map:
 *   1. exact `accounts[<row.category>]`
 *   2. first `rules[]` whose `match` (case-insensitive substring) hits the
 *      row's description/memo
 *   3. null → unmapped
 */
export function resolveAccount(row, accountMap) {
  const category = (row.category || row.type || "").trim();
  const accounts = accountMap.accounts || {};
  if (category && accounts[category]) return accounts[category];
  const haystack = `${row.description || ""} ${row.memo || ""} ${row.name || ""}`.toLowerCase();
  for (const rule of accountMap.rules || []) {
    if (rule.match && haystack.includes(String(rule.match).toLowerCase())) {
      return rule.account;
    }
  }
  return null;
}

// ── Entry construction ────────────────────────────────────────────────────

function line(name, side, amount) {
  return { accountRef: accountRefFor(name), accountId: entityId("account", name), side, amount };
}

/** Throws if a built entry is not balanced (defensive — construction guarantees it). */
export function assertBalanced(entry) {
  const cents = (x) => Math.round(x * 100);
  let d = 0,
    c = 0;
  for (const l of entry.lines) (l.side === "debit" ? (d += cents(l.amount)) : (c += cents(l.amount)));
  if (d !== c) {
    throw new Error(`acct-import produced an unbalanced entry "${entry.canonical_name}": debits ${d / 100} != credits ${c / 100}`);
  }
}

/**
 * Build a balanced journal entry for one statement row, or classify it as
 * unmapped. Returns { status, entry?, unmapped? }.
 *
 *   amount > 0 (money IN)  → debit bank, credit category
 *   amount < 0 (money OUT) → credit bank, debit category
 */
export function buildEntryForRow(row, opts) {
  const { bankAccount, accountMap, postMappedOnly, now } = opts;
  const amount = rowAmount(row);
  if (!Number.isFinite(amount) || amount === 0) {
    return { status: "skipped", reason: "no usable amount", row };
  }
  let categoryName = resolveAccount(row, accountMap);
  let routedToSuspense = false;
  if (!categoryName) {
    if (!postMappedOnly) {
      return {
        status: "unmapped",
        row,
        category: (row.category || row.description || "").trim(),
      };
    }
    categoryName = accountMap.suspenseAccount || "Suspense";
    routedToSuspense = true;
  }

  const magnitude = Math.abs(amount);
  const bankSide = amount > 0 ? "debit" : "credit";
  const catSide = amount > 0 ? "credit" : "debit";
  const lines = [
    line(bankAccount, bankSide, magnitude),
    line(categoryName, catSide, magnitude),
  ];

  const date = (row.date || row["posted date"] || "").trim();
  const desc = (row.description || row.memo || row.name || "transaction").trim();
  const qbo = rowKey(row);
  // Stable canonical name → stable id → idempotent re-import.
  const stableKey = qbo || createHash("sha256").update(`${date}|${desc}|${amount}|${bankAccount}`).digest("hex").slice(0, 12);
  const canonical = `import ${stableKey}`;
  const iso = (now || (() => new Date().toISOString()))();

  const entry = {
    id: entityId("journal-entry", canonical),
    type: "journal-entry",
    canonical_name: canonical,
    aliases: [],
    confidence: 1,
    status: "confirmed",
    domain: ["accounting"],
    first_seen: iso,
    last_updated: iso,
    signal_count: 0,
    entryDate: date,
    currency: accountMap.baseCurrency || "USD",
    memo: desc,
    lines,
    ...(qbo ? { external_ids: { quickbooks: qbo } } : {}),
  };
  assertBalanced(entry);
  return { status: routedToSuspense ? "suspense" : "mapped", entry };
}

/** Run the import over parsed rows. Pure — returns the plan, writes nothing. */
export function runImport({ rows, bankAccount, accountMap, postMappedOnly = false, now }) {
  const entries = [];
  const unmapped = [];
  const skipped = [];
  let suspenseCount = 0;
  for (const row of rows) {
    const r = buildEntryForRow(row, { bankAccount, accountMap, postMappedOnly, now });
    if (r.status === "unmapped") unmapped.push(r);
    else if (r.status === "skipped") skipped.push(r);
    else {
      entries.push(r.entry);
      if (r.status === "suspense") suspenseCount++;
    }
  }
  return {
    entries,
    unmapped,
    skipped,
    summary: {
      rows: rows.length,
      posted: entries.length,
      suspense: suspenseCount,
      unmapped: unmapped.length,
      skipped: skipped.length,
      unmappedCategories: [...new Set(unmapped.map((u) => u.category).filter(Boolean))].sort(),
    },
  };
}

// ── Markdown serialization (hq-pro entity file shape) ─────────────────────

function yamlScalar(v) {
  if (typeof v === "number") return String(v);
  const s = String(v);
  return /[:#\-?{}\[\],&*!|>'"%@`]/.test(s) || s.trim() !== s ? JSON.stringify(s) : s;
}

export function serializeEntryMarkdown(entry) {
  const fm = [];
  fm.push(`id: ${entry.id}`);
  fm.push(`type: ${entry.type}`);
  fm.push(`canonical_name: ${yamlScalar(entry.canonical_name)}`);
  fm.push(`aliases: []`);
  fm.push(`confidence: ${entry.confidence}`);
  fm.push(`status: ${entry.status}`);
  fm.push(`domain: [${entry.domain.map(yamlScalar).join(", ")}]`);
  fm.push(`first_seen: ${yamlScalar(entry.first_seen)}`);
  fm.push(`last_updated: ${yamlScalar(entry.last_updated)}`);
  fm.push(`signal_count: ${entry.signal_count}`);
  if (entry.entryDate) fm.push(`entryDate: ${yamlScalar(entry.entryDate)}`);
  if (entry.currency) fm.push(`currency: ${yamlScalar(entry.currency)}`);
  if (entry.memo) fm.push(`memo: ${yamlScalar(entry.memo)}`);
  if (entry.external_ids) {
    fm.push(`external_ids:`);
    for (const [k, v] of Object.entries(entry.external_ids)) fm.push(`  ${k}: ${yamlScalar(v)}`);
  }
  fm.push(`lines:`);
  for (const l of entry.lines) {
    fm.push(`  - accountRef: ${yamlScalar(l.accountRef)}`);
    fm.push(`    accountId: ${l.accountId}`);
    fm.push(`    side: ${l.side}`);
    fm.push(`    amount: ${l.amount}`);
  }
  const rels = entry.lines.map((l) => {
    const name = l.accountRef.replace(/^\.\.\/account\//, "").replace(/\.md$/, "");
    const verb = l.side === "debit" ? "Debits" : "Credits";
    return `- ${verb} [${name}](${l.accountRef})`;
  });
  return `---\n${fm.join("\n")}\n---\n\n## Relationships\n\n${rels.join("\n")}\n`;
}

// ── CLI ───────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const args = { postMappedOnly: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--csv") args.csv = argv[++i];
    else if (a === "--map") args.map = argv[++i];
    else if (a === "--bank") args.bank = argv[++i];
    else if (a === "--out") args.out = argv[++i];
    else if (a === "--post-mapped-only") args.postMappedOnly = true;
    else if (a === "--dry-run") args.dryRun = true;
  }
  return args;
}

function main(argv) {
  const args = parseArgs(argv);
  if (!args.csv || !args.map) {
    console.error(
      "Usage: acct-import --csv <statement.csv> --map <account-map.json> [--bank <account name>] [--out <ontology entities dir>] [--post-mapped-only] [--dry-run]",
    );
    process.exit(2);
  }
  const accountMap = JSON.parse(readFileSync(args.map, "utf-8"));
  const bankAccount = args.bank || accountMap.bankAccount;
  if (!bankAccount) {
    console.error("No bank account: pass --bank or set bankAccount in the map.");
    process.exit(2);
  }
  const rows = parseCsv(readFileSync(args.csv, "utf-8"));
  const result = runImport({ rows, bankAccount, accountMap, postMappedOnly: args.postMappedOnly });

  console.log(JSON.stringify({ summary: result.summary }, null, 2));
  if (result.unmapped.length > 0 && !args.postMappedOnly) {
    console.error(
      `\n${result.unmapped.length} row(s) reference categories not in your chart of accounts:\n  ${result.summary.unmappedCategories.join("\n  ")}\n` +
        `Map them in ${args.map} (or add a rule), or re-run with --post-mapped-only to route them to Suspense.`,
    );
  }
  if (!args.dryRun && args.out) {
    for (const entry of result.entries) {
      const dir = join(args.out, "journal-entry");
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, `${slugify(entry.canonical_name)}.md`), serializeEntryMarkdown(entry));
    }
    console.log(`\nWrote ${result.entries.length} journal entr(y/ies) under ${args.out}/journal-entry/.`);
  }
  // Non-zero exit when there are unposted (unmapped) rows and we are not in
  // suspense-routing mode, so a caller/CI notices the review queue.
  if (result.unmapped.length > 0 && !args.postMappedOnly) process.exit(1);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2));
}
