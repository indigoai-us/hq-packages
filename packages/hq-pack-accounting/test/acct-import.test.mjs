import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseCsv,
  parseAmount,
  resolveAccount,
  buildEntryForRow,
  runImport,
  serializeEntryMarkdown,
  assertBalanced,
  entityId,
} from "../scripts/acct-import.mjs";

const NOW = () => "2026-06-23T00:00:00.000Z";

const MAP = {
  version: 1,
  baseCurrency: "USD",
  bankAccount: "Operating Checking",
  accounts: { "Consulting Income": "Consulting Income", Rent: "Rent Expense" },
  rules: [{ match: "AWS", account: "Software Expense" }],
  suspenseAccount: "Suspense",
};

const CSV = `date,description,category,amount
2026-02-01,Client payment,Consulting Income,"1,000.00"
2026-03-01,Office rent,Rent,-500.00
2026-03-05,AWS invoice,,(90.00)
2026-03-10,Mystery charge,,-25.00
`;

test("parseCsv handles headers, quotes, embedded commas", () => {
  const rows = parseCsv(CSV);
  assert.equal(rows.length, 4);
  assert.equal(rows[0].description, "Client payment");
  assert.equal(rows[0].amount, "1,000.00");
});

test("parseAmount handles $, commas, and parentheses-negatives", () => {
  assert.equal(parseAmount("1,000.00"), 1000);
  assert.equal(parseAmount("$1,234.56"), 1234.56);
  assert.equal(parseAmount("(90.00)"), -90);
  assert.equal(parseAmount("-500"), -500);
});

test("resolveAccount: exact category, then rule, then unmapped", () => {
  assert.equal(resolveAccount({ category: "Rent" }, MAP), "Rent Expense");
  assert.equal(resolveAccount({ description: "AWS invoice" }, MAP), "Software Expense");
  assert.equal(resolveAccount({ description: "Mystery" }, MAP), null);
});

test("buildEntryForRow: money-in debits the bank, credits the category; balanced", () => {
  const r = buildEntryForRow(
    { date: "2026-02-01", description: "Client payment", category: "Consulting Income", amount: "1000" },
    { bankAccount: "Operating Checking", accountMap: MAP, now: NOW },
  );
  assert.equal(r.status, "mapped");
  const bank = r.entry.lines.find((l) => l.accountId === entityId("account", "Operating Checking"));
  const cat = r.entry.lines.find((l) => l.accountId === entityId("account", "Consulting Income"));
  assert.equal(bank.side, "debit");
  assert.equal(cat.side, "credit");
  assert.equal(bank.amount, 1000);
  assert.equal(cat.amount, 1000);
  assert.doesNotThrow(() => assertBalanced(r.entry));
});

test("buildEntryForRow: money-out credits the bank, debits the category", () => {
  const r = buildEntryForRow(
    { date: "2026-03-01", description: "Office rent", category: "Rent", amount: "-500" },
    { bankAccount: "Operating Checking", accountMap: MAP, now: NOW },
  );
  const bank = r.entry.lines.find((l) => l.accountId === entityId("account", "Operating Checking"));
  const cat = r.entry.lines.find((l) => l.accountId === entityId("account", "Rent Expense"));
  assert.equal(bank.side, "credit");
  assert.equal(cat.side, "debit");
});

test("buildEntryForRow is idempotent: same row → same entity id", () => {
  const row = { date: "2026-02-01", description: "Client payment", category: "Consulting Income", amount: "1000" };
  const a = buildEntryForRow(row, { bankAccount: "Operating Checking", accountMap: MAP, now: NOW });
  const b = buildEntryForRow(row, { bankAccount: "Operating Checking", accountMap: MAP, now: NOW });
  assert.equal(a.entry.id, b.entry.id);
});

test("a transaction id flows into external_ids.quickbooks and drives the id", () => {
  const r = buildEntryForRow(
    { date: "2026-02-01", description: "x", category: "Rent", amount: "-10", "transaction id": "qbo_123" },
    { bankAccount: "Operating Checking", accountMap: MAP, now: NOW },
  );
  assert.equal(r.entry.external_ids.quickbooks, "qbo_123");
  assert.equal(r.entry.id, entityId("journal-entry", "import qbo_123"));
});

test("runImport: maps known rows, surfaces unmapped, blocks posting by default", () => {
  const result = runImport({ rows: parseCsv(CSV), bankAccount: "Operating Checking", accountMap: MAP, now: NOW });
  assert.equal(result.summary.posted, 3);
  assert.equal(result.summary.unmapped, 1);
  assert.deepEqual(result.summary.unmappedCategories, ["Mystery charge"]);
  // Every posted entry is balanced.
  for (const e of result.entries) assert.doesNotThrow(() => assertBalanced(e));
});

test("runImport --post-mapped-only routes unmapped rows to Suspense (nothing left unposted)", () => {
  const result = runImport({
    rows: parseCsv(CSV),
    bankAccount: "Operating Checking",
    accountMap: MAP,
    postMappedOnly: true,
    now: NOW,
  });
  assert.equal(result.summary.posted, 4);
  assert.equal(result.summary.suspense, 1);
  assert.equal(result.summary.unmapped, 0);
  const suspense = result.entries.find((e) =>
    e.lines.some((l) => l.accountId === entityId("account", "Suspense")),
  );
  assert.ok(suspense, "an entry should route to Suspense");
  assertBalanced(suspense);
});

test("serializeEntryMarkdown emits frontmatter + relationships", () => {
  const r = buildEntryForRow(
    { date: "2026-02-01", description: "Client payment", category: "Consulting Income", amount: "1000", "transaction id": "qbo_9" },
    { bankAccount: "Operating Checking", accountMap: MAP, now: NOW },
  );
  const md = serializeEntryMarkdown(r.entry);
  assert.match(md, /^---\n/);
  assert.match(md, /type: journal-entry/);
  assert.match(md, /quickbooks: qbo_9/);
  assert.match(md, /## Relationships/);
  assert.match(md, /Debits \[operating-checking\]/);
  assert.match(md, /Credits \[consulting-income\]/);
});

test("assertBalanced throws on a hand-built unbalanced entry", () => {
  assert.throws(() =>
    assertBalanced({
      canonical_name: "bad",
      lines: [
        { side: "debit", amount: 100 },
        { side: "credit", amount: 90 },
      ],
    }),
  );
});
