/**
 * Fixture smoke harness for the secure capability-bridge sidecar.
 *
 * Builds a temporary fixture tree, runs the safety-critical paths, and asserts
 * outcomes + the append-only audit log. No real secrets, no daemon, no network.
 *
 *   npx tsx smoke-harness.ts          # human-readable
 *   npx tsx smoke-harness.ts --json   # machine-readable
 *   bun smoke-harness.ts              # also works under Bun
 *
 * Exit code 0 = all assertions passed; 1 = a failure (treat as release blocker).
 */
import fs from 'fs';
import os from 'os';
import path from 'path';

import { evaluateCapability, type BridgeConfig, type Outcome } from './capability-bridge.js';

const wantJson = process.argv.includes('--json');

interface Step {
  name: string;
  expected: Outcome;
  actual?: Outcome;
  pass: boolean;
  detail?: string;
}

async function main(): Promise<void> {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'secure-sidecar-smoke-'));
  const steps: Step[] = [];
  try {
    // Lay out a fixture tree: an allowlisted "status" root, a "records"
    // read-write root, and a "secrets" root that must NEVER be reachable.
    fs.mkdirSync(path.join(fixture, 'status'), { recursive: true });
    fs.mkdirSync(path.join(fixture, 'records'), { recursive: true });
    fs.mkdirSync(path.join(fixture, 'secrets'), { recursive: true });
    fs.writeFileSync(
      path.join(fixture, 'status', 'latest.json'),
      JSON.stringify({ title: 'demo', summary: 'fixture status with token apple banana', status: 'green' }),
    );
    fs.writeFileSync(path.join(fixture, 'secrets', '.env'), 'API_KEY=should-never-be-read');

    const auditLogPath = path.join(fixture, 'audit.jsonl');
    const config: BridgeConfig = {
      treeRoot: fixture,
      allowedRoots: [
        { path: 'status', access: 'read' },
        { path: 'records', access: 'read-write' },
      ],
      deniedPathPatterns: ['.env', 'secret', 'credential', 'token', '.ssh', '.aws'],
      deniedActionWords: ['shell', 'exec', 'bash', 'deploy', 'publish', 'commit', 'push', 'install', 'curl'],
      statusRoot: 'status',
      mutationScope: 'records',
      createRecordConfirmationPhrase: 'confirm create record',
      auditLogPath,
    };

    // 1. allowed read
    const status = await evaluateCapability({ capability: 'read_status', channel: 'cli', requester: 'tester' }, config);
    steps.push(checkStep('read_status', 'allowed', status.outcome, status.message));

    // 2. scoped search (explicit allowlisted scope)
    const searchRes = await evaluateCapability(
      { capability: 'search', query: 'banana', scope: 'status', channel: 'cli', requester: 'tester' },
      config,
    );
    steps.push(checkStep('search', 'allowed', searchRes.outcome, `${searchRes.sources.length} source(s)`));

    // 3. pending mutation — returns envelope, writes nothing
    const pending = await evaluateCapability(
      { capability: 'create_record', summary: 'queue a note', channel: 'cli', requester: 'tester' },
      config,
    );
    const wroteNothingYet = pending.filesWritten.length === 0 && !!pending.mutation;
    steps.push({
      name: 'create_record (pending)',
      expected: 'allowed',
      actual: pending.outcome,
      pass: pending.outcome === 'allowed' && wroteNothingYet,
      detail: wroteNothingYet ? 'envelope returned, no write' : 'unexpectedly wrote during pending',
    });

    // 4. confirmed mutation — writes exactly one record under the mutation scope
    const confirmed = await evaluateCapability(
      {
        capability: 'create_record',
        summary: 'queue a note',
        confirmationState: 'confirmed',
        confirmation: 'confirm create record',
        channel: 'cli',
        requester: 'tester',
      },
      config,
    );
    const wroteOneInScope =
      confirmed.filesWritten.length === 1 && confirmed.filesWritten[0].startsWith('records/');
    steps.push({
      name: 'create_record (confirmed)',
      expected: 'completed',
      actual: confirmed.outcome,
      pass: confirmed.outcome === 'completed' && wroteOneInScope,
      detail: wroteOneInScope ? confirmed.filesWritten[0] : 'did not write exactly one record in scope',
    });

    // 5. denied action — a shell request reads nothing and writes nothing
    const denied = await evaluateCapability(
      { capability: 'run_shell', action: 'exec rm -rf', channel: 'cli', requester: 'tester' },
      config,
    );
    steps.push({
      name: 'denied action (run_shell)',
      expected: 'denied',
      actual: denied.outcome,
      pass: denied.outcome === 'denied' && denied.filesRead.length === 0 && denied.filesWritten.length === 0,
      detail: denied.denialReason,
    });

    // 6. denied path — asking for the secrets/.env path is refused
    const deniedPath = await evaluateCapability(
      { capability: 'search', query: 'API_KEY', scope: 'secrets/.env', channel: 'cli', requester: 'tester' },
      config,
    );
    steps.push({
      name: 'denied path (secrets/.env)',
      expected: 'denied',
      actual: deniedPath.outcome,
      pass: deniedPath.outcome === 'denied' && deniedPath.filesRead.length === 0,
      detail: deniedPath.denialReason,
    });

    // Audit assertion: one append-only line per request, none referencing secrets.
    const auditLines = fs.readFileSync(auditLogPath, 'utf8').trim().split('\n').filter(Boolean);
    const auditOk = auditLines.length === steps.length && !auditLines.some((l) => l.includes('should-never-be-read'));
    steps.push({
      name: 'audit log',
      expected: 'allowed',
      actual: auditOk ? 'allowed' : 'failed',
      pass: auditOk,
      detail: `${auditLines.length} entries (expected ${steps.length})`,
    });
  } finally {
    fs.rmSync(fixture, { recursive: true, force: true });
  }

  const passed = steps.every((s) => s.pass);
  if (wantJson) {
    console.log(JSON.stringify({ passed, steps }, null, 2));
  } else {
    for (const s of steps) {
      const mark = s.pass ? 'PASS' : 'FAIL';
      console.log(`[${mark}] ${s.name} — expected ${s.expected}, got ${s.actual ?? 'n/a'}${s.detail ? ` (${s.detail})` : ''}`);
    }
    console.log(passed ? '\nAll smoke assertions passed.' : '\nSmoke FAILED.');
  }
  process.exit(passed ? 0 : 1);
}

function checkStep(name: string, expected: Outcome, actual: Outcome, detail?: string): Step {
  return { name, expected, actual, pass: actual === expected, detail };
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
