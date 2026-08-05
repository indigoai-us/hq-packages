#!/usr/bin/env node
/**
 * codex-workflow.mjs — Workflow-tool-style multi-agent orchestration over Codex.
 *
 * Runs a plain-JavaScript orchestration script (same authoring shape as the
 * Claude Code Workflow tool: agent()/parallel()/pipeline()/phase()/log()/
 * workflow(), top-level await, top-level return) where EVERY agent() call is
 * a `codex exec` subprocess instead of a Claude subagent.
 *
 * Every spawn carries the mandated flags:
 *   --dangerously-bypass-hook-trust             (never stall on a hook-trust prompt)
 *   --skip-git-repo-check                       (safe outside a git repo / at HQ root)
 *   --dangerously-bypass-approvals-and-sandbox  (unattended full-auto)
 * plus the HQ hardening rules:
 *   - soft per-agent timeout: on expiry the agent is NOT killed — a
 *     TIMEOUT WARNING line is printed to stdout and repeated every timeout
 *     interval (10-min timeout -> a warning at 10, 20, 30 min, ...) so the
 *     orchestrator watching the output can decide to kill the process group
 *     (`kill -- -<pid>`) or let the agent keep running
 *   - stdin closed — spawned with stdin at /dev/null (a non-interactive
 *     `codex exec` otherwise blocks forever waiting for stdin EOF)
 *   - every agent is anchored at the HQ root (-C <HQ_ROOT>), never at a
 *     worktree. Codex loads its hook config from the project directory it is
 *     launched in, and only the HQ root carries HQ's .codex/config.toml — an
 *     agent spawned with -C <worktree> silently runs with every PreToolUse
 *     safety rail disabled. Worktree-scoped work is targeted through the
 *     PROMPT instead (see opts.cd below).
 *   - stdout/stderr streamed to a per-agent log file; the final message is
 *     read from a dedicated --output-last-message file, never tailed out of
 *     the verbose transcript (transcripts run to hundreds of KB)
 *
 * Usage (installed under .claude/skills/hq-pack-engineering:ideate/scripts/):
 *   node <path-to>/codex-workflow.mjs <script.mjs> [options]
 *   node <path-to>/codex-workflow.mjs --eval '<script source>' [options]
 *
 * Options:
 *   --args <json>        Value exposed to the script as `args` (JSON, falls
 *                        back to the raw string if it does not parse)
 *   --concurrency <n>    Max concurrent codex processes
 *                        (default: min(16, cores-2), env CODEX_WORKFLOW_CONCURRENCY;
 *                        a high-CPU check may halve the resolved value before the
 *                        run starts — see CODEX_WORKFLOW_CPU_CHECK below)
 *   --timeout <secs>     Default per-agent soft timeout — the warning interval;
 *                        agents are never killed on expiry
 *                        (default: 1800, env CODEX_TIMEOUT_SECS)
 *   --run-dir <dir>      Where logs/journal land
 *                        (default: <hq-root>/workspace/tmp/codex-workflow/<runId>)
 *   --quiet              Suppress narrator lines on stderr
 *
 * Env:
 *   CODEX_WORKFLOW_FAST_MODE   Fast mode (`-c service_tier="fast" --enable
 *                              fast_mode` — ~1.5x faster, more credits,
 *                              ChatGPT-auth only) defaults per tier: ON for
 *                              terra, OFF for sol. Set 1/true/on/yes to force it
 *                              on for every tier, 0/false/off/no to force it off
 *                              for the whole run.
 *   CODEX_WORKFLOW_MODEL       Global model pin. Unset (normal) -> the per-agent
 *                              tier selects the model (sol -> gpt-5.6-sol,
 *                              terra -> gpt-5.6-terra). Set -> overrides the
 *                              tier for every spawn; empty string -> use codex
 *                              config.toml default.
 *   CODEX_WORKFLOW_EFFORT      Default reasoning effort (default high). Empty
 *                              string -> use codex config.toml default.
 *   CODEX_WORKFLOW_MODEL_SOL   Model behind the "sol" tier (default gpt-5.6-sol).
 *   CODEX_WORKFLOW_MODEL_TERRA Model behind the "terra" tier
 *                              (default gpt-5.6-terra).
 *   HQ_ROOT                    Explicit HQ root override. Unset -> auto-detected
 *                              by walking up from this script (then cwd) to the
 *                              first dir with companies/manifest.yaml or
 *                              .claude/settings.json.
 *   CODEX_WORKFLOW_CPU_CHECK   High-CPU governor. ON by default: before the run
 *                              starts it samples CPU utilization and, if it is
 *                              at/above the threshold, halves the resolved
 *                              concurrency (floor 1) and logs a warning to
 *                              stderr. Set to 0/false/off/no to disable.
 *   CODEX_WORKFLOW_CPU_HIGH_THRESHOLD  Busy fraction (0<t<=1) that counts as
 *                              "high" for the governor (default 0.85 = 85%).
 *
 * Script API (mirrors the Workflow tool):
 *   agent(prompt, opts) -> Promise<string|object>
 *     opts.tier (REQUIRED): "sol" (analysis/planning -> gpt-5.6-sol) or "terra"
 *           (execution -> gpt-5.6-terra). agent() throws if it is missing or
 *           not one of these — every worker must pick a tier explicitly.
 *     opts: label, phase, schema (JSON Schema -> --output-schema, result is
 *           parsed JSON), model (-m; explicit override of the tier's model),
 *           effort (-c model_reasoning_effort=, default xhigh), fastMode (bool;
 *           overrides CODEX_WORKFLOW_FAST_MODE and the per-tier default of
 *           terra=on / sol=off for this one agent),
 *           cd (target directory for the task — MUST resolve inside the HQ
 *           root; it is NOT passed as -C. Every agent spawns with
 *           -C <HQ_ROOT> so HQ's codex hooks load; a cd other than the HQ
 *           root is injected as a working-directory preamble on the prompt.
 *           Defaults to the HQ root), timeoutSecs (soft —
 *           warning interval, never a kill), extraArgs (string[])
 *     Throws on non-zero exit or spawn failure; the error message carries the
 *     log path. A timeout alone never throws — it only emits stdout warnings.
 *   parallel(thunks)     -> Promise<any[]>  barrier; a thrown thunk resolves to
 *                           null, the call itself never rejects
 *   pipeline(items, ...stages) -> Promise<any[]>  no barrier between stages;
 *                           stage callbacks receive (prev, originalItem, index);
 *                           a throwing stage drops that item to null
 *   phase(title)         -> narrator grouping for subsequent agent() calls
 *   log(msg)             -> narrator line on stderr
 *   workflow(ref, args?) -> run another script file inline (one level deep);
 *                           ref is a path string or {scriptPath}
 *   gate(id, question, opts?) -> Promise<answer>  human-in-the-loop pause.
 *     Writes a self-contained question file to <gates>/pending/<id>.json,
 *     prints a GATE OPEN line to stdout (even under --quiet — it is the wake
 *     signal a watching orchestrator tails), and polls until
 *     <gates>/answered/<id>.json exists, then resumes IN PLACE and returns the
 *     parsed answer ({choice, notes?, answered_by?, answered_at}). No agents
 *     run while a gate is waiting and no concurrency slot is held. Answers are
 *     durable: an already-answered id returns instantly (GATE CACHED), so a
 *     re-launched run never re-asks a human. Answer with
 *     `bash core/scripts/workflow-gate.sh answer <id> <choice|N>`.
 *     opts: options ([{label, description?}] or string[]), context (string),
 *           recommended (label), pollSecs (default 5,
 *           env CODEX_WORKFLOW_GATE_POLL_SECS)
 *   args                 -> the --args value
 *   budget               -> stub: {total: null, spent(): 0, remaining(): Infinity}.
 *                           Token spend is NOT tracked for Codex runs; budget-
 *                           guarded loops behave as if no target was set.
 *
 * The script's top-level return value is printed to stdout as JSON.
 * Environment: CODEX_WORKFLOW_CODEX_BIN overrides the codex binary (tests);
 * CODEX_WORKFLOW_CPU_BUSY_OVERRIDE injects a fixed CPU busy fraction (0..1) and
 * skips live sampling (tests / forcing the high-CPU path);
 * CODEX_WORKFLOW_GATES_DIR overrides where gate() question/answer files live
 * (default <hq-root>/workspace/gates — override in tests for hermeticity);
 * CODEX_WORKFLOW_GATE_POLL_SECS overrides the default gate poll interval.
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// HQ root resolution, in precedence order: explicit HQ_ROOT env; the nearest
// ancestor of this script that looks like an HQ root (carries
// companies/manifest.yaml, or a .claude/settings.json); the same walk from
// process.cwd(). The pack installs this script under
// <hq>/.claude/skills/hq-pack-engineering:ideate/scripts/, so the script-dir
// walk finds the root in a normal install; the env override serves tests and
// unusual layouts.
function looksLikeHqRoot(dir) {
  return fs.existsSync(path.join(dir, 'companies', 'manifest.yaml'))
    || fs.existsSync(path.join(dir, '.claude', 'settings.json'));
}
function findHqRoot() {
  if (process.env.HQ_ROOT) return path.resolve(process.env.HQ_ROOT);
  for (const start of [__dirname, process.cwd()]) {
    let dir = path.resolve(start);
    for (;;) {
      if (looksLikeHqRoot(dir)) return dir;
      const parent = path.dirname(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }
  process.stderr.write('codex-workflow: cannot locate the HQ root — set HQ_ROOT\n');
  process.exit(2);
}
const HQ_ROOT = findHqRoot();

const CODEX_BIN = process.env.CODEX_WORKFLOW_CODEX_BIN || 'codex';
const MANDATED_FLAGS = [
  '--dangerously-bypass-hook-trust',
  '--skip-git-repo-check',
  '--dangerously-bypass-approvals-and-sandbox',
];
// Fast mode (https://developers.openai.com/codex/speed): ~1.5x faster model
// responses at elevated credit cost (GPT-5.5 2.5x, GPT-5.4 2x), ChatGPT-auth
// only — API-key auth silently gets standard speed. Per the docs it needs BOTH
// the service tier and the feature flag.
//
// Default is per-tier: ON for terra (execution — throughput is the point) and
// OFF for sol (analysis/planning — we want its full reasoning, and it is the
// expensive tier to multiply). Override globally with CODEX_WORKFLOW_FAST_MODE
// (1/true/on/yes forces it on for every tier, 0/false/off/no forces it off), or
// per-agent via opts.fastMode.
const FAST_MODE_FLAGS = ['-c', 'service_tier="fast"', '--enable', 'fast_mode'];
const FAST_MODE_TIER_DEFAULTS = { sol: false, terra: true };
// undefined when unset/blank -> fall through to the per-tier default.
const FAST_MODE_ENV = (() => {
  const raw = (process.env.CODEX_WORKFLOW_FAST_MODE || '').trim();
  if (!raw) return undefined;
  if (/^(0|false|off|no)$/i.test(raw)) return false;
  return true;
})();
// Tier -> model. Every agent() must pick a tier explicitly (enforced in
// agent()) so the orchestrator's model choice is never implicit:
//   sol   -> gpt-5.6-sol   (flagship — use for analysis & planning)
//   terra -> gpt-5.6-terra (balanced/cheaper — use for execution)
const TIER_MODELS = {
  sol: process.env.CODEX_WORKFLOW_MODEL_SOL || 'gpt-5.6-sol',
  terra: process.env.CODEX_WORKFLOW_MODEL_TERRA || 'gpt-5.6-terra',
};
const VALID_TIERS = Object.keys(TIER_MODELS);
// Optional global model pin. Unset (the normal case) -> the per-agent tier
// selects the model. Set -> overrides the tier-derived model for every spawn;
// an empty string means "let codex config.toml decide" (no -m flag). Per-agent
// opts.model still wins over this pin.
const MODEL_OVERRIDE = process.env.CODEX_WORKFLOW_MODEL; // undefined if unset
// Default reasoning effort for every spawn. Per-agent opts.effort overrides it;
// env CODEX_WORKFLOW_EFFORT overrides the default; empty string -> codex
// config.toml default.
const DEFAULT_EFFORT = process.env.CODEX_WORKFLOW_EFFORT ?? 'high';
const MAX_AGENTS = 1000; // runaway-loop backstop, same ceiling as the Workflow tool

// CPU governor: before committing to the resolved concurrency, sample real CPU
// utilization. If the box is already saturated, fanning out the full set of
// codex processes just thrashes it and slows every agent — so halve the
// concurrency (floor 1) and warn. On by default; opt out with
// CODEX_WORKFLOW_CPU_CHECK=0 (or false/off/no). CODEX_WORKFLOW_CPU_HIGH_THRESHOLD
// (fraction 0<t<=1, default 0.85) sets what counts as "high".
// CODEX_WORKFLOW_CPU_BUSY_OVERRIDE injects a fixed busy fraction and skips real
// sampling (tests / forcing the high-CPU path).
const CPU_CHECK_ENABLED = !/^(0|false|off|no)$/i.test(process.env.CODEX_WORKFLOW_CPU_CHECK || '');
const CPU_HIGH_THRESHOLD = (() => {
  const raw = process.env.CODEX_WORKFLOW_CPU_HIGH_THRESHOLD;
  const v = Number(raw);
  return raw !== undefined && raw !== '' && Number.isFinite(v) && v > 0 && v <= 1 ? v : 0.85;
})();
const CPU_SAMPLE_MS = 200;

// Human gates: gate() question/answer files. A well-known location outside the
// per-run dir, so ANY session (not just the launcher) can list and answer them,
// and so answers survive the run that asked — a re-launched workflow returns
// them instantly instead of re-asking the human.
const GATES_DIR = process.env.CODEX_WORKFLOW_GATES_DIR || path.join(HQ_ROOT, 'workspace', 'gates');
const DEFAULT_GATE_POLL_SECS = (() => {
  const v = Number(process.env.CODEX_WORKFLOW_GATE_POLL_SECS);
  return Number.isFinite(v) && v > 0 ? v : 5;
})();

// ---------------------------------------------------------------- CLI parsing

function usageAndExit(code) {
  const header = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8');
  const doc = header.slice(header.indexOf('/**'), header.indexOf('*/') + 2);
  process.stderr.write(doc + '\n');
  process.exit(code);
}

function parseCli(argv) {
  const cli = {
    scriptPath: null,
    evalSrc: null,
    args: undefined,
    concurrency: null,
    timeoutSecs: null,
    runDir: null,
    quiet: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = (name) => {
      if (i + 1 >= argv.length) {
        process.stderr.write(`codex-workflow: ${name} requires a value\n`);
        process.exit(2);
      }
      return argv[++i];
    };
    switch (a) {
      case '--help': case '-h': usageAndExit(0); break;
      case '--eval': cli.evalSrc = next('--eval'); break;
      case '--args': {
        const raw = next('--args');
        try { cli.args = JSON.parse(raw); } catch { cli.args = raw; }
        break;
      }
      case '--concurrency': cli.concurrency = next('--concurrency'); break;
      case '--timeout': cli.timeoutSecs = next('--timeout'); break;
      case '--run-dir': cli.runDir = next('--run-dir'); break;
      case '--quiet': cli.quiet = true; break;
      default:
        if (a.startsWith('-')) {
          process.stderr.write(`codex-workflow: unknown option ${a}\n`);
          process.exit(2);
        }
        if (cli.scriptPath) {
          process.stderr.write('codex-workflow: only one script path allowed\n');
          process.exit(2);
        }
        cli.scriptPath = a;
    }
  }
  if (!cli.scriptPath && !cli.evalSrc) usageAndExit(2);
  if (cli.scriptPath && cli.evalSrc) {
    process.stderr.write('codex-workflow: pass a script path OR --eval, not both\n');
    process.exit(2);
  }
  return cli;
}

// ------------------------------------------------------------------ utilities

function hhmmss() {
  return new Date().toISOString().slice(11, 19);
}

function errMsg(e) {
  return e instanceof Error ? e.message : String(e);
}

// The child is spawned detached so it leads its own process group; signal the
// whole group (-pid) so codex AND everything codex spawned die together. Falls
// back to the single PID if the group is already gone.
function killTree(child, sig) {
  try {
    process.kill(-child.pid, sig);
  } catch {
    try { child.kill(sig); } catch { /* already gone */ }
  }
}

class Semaphore {
  constructor(n) { this.free = n; this.queue = []; }
  async acquire() {
    if (this.free > 0) { this.free--; return; }
    await new Promise((resolve) => this.queue.push(resolve));
  }
  release() {
    const next = this.queue.shift();
    if (next) next(); else this.free++;
  }
}

function tailOfFile(file, bytes) {
  try {
    const size = fs.statSync(file).size;
    const fd = fs.openSync(file, 'r');
    try {
      const start = Math.max(0, size - bytes);
      const buf = Buffer.alloc(size - start);
      fs.readSync(fd, buf, 0, buf.length, start);
      return buf.toString('utf8');
    } finally {
      fs.closeSync(fd);
    }
  } catch (e) {
    return `<could not read log tail: ${e.message}>`;
  }
}

function parseMaybeJson(text, context) {
  const trimmed = text.trim();
  try { return JSON.parse(trimmed); } catch { /* fall through to fence extraction */ }
  const fence = trimmed.match(/```(?:json)?\s*\n([\s\S]*?)\n```/);
  if (fence) {
    try { return JSON.parse(fence[1]); } catch { /* fall through to throw */ }
  }
  throw new Error(`schema result is not valid JSON (${context})`);
}

// Aggregate CPU time counters across all cores (idle + busy ticks). os.cpus()
// can be empty in constrained sandboxes; callers treat a null busy fraction as
// "unknown -> don't throttle".
function cpuTimesSnapshot() {
  const cpus = os.cpus() || [];
  let idle = 0, total = 0;
  for (const cpu of cpus) {
    const t = cpu.times;
    idle += t.idle;
    total += t.user + t.nice + t.sys + t.idle + t.irq;
  }
  return { idle, total };
}

// Real instantaneous CPU utilization: diff the idle/total tick counters across
// a short interval and return the busy ratio in [0,1], or null if it can't be
// measured (no cores, or no ticks elapsed).
async function sampleCpuBusyFraction(ms) {
  try {
    const a = cpuTimesSnapshot();
    await new Promise((resolve) => setTimeout(resolve, ms));
    const b = cpuTimesSnapshot();
    const idleDelta = b.idle - a.idle;
    const totalDelta = b.total - a.total;
    if (!(totalDelta > 0)) return null;
    return Math.max(0, Math.min(1, 1 - idleDelta / totalDelta));
  } catch {
    return null;
  }
}

// Busy fraction the governor acts on: a CODEX_WORKFLOW_CPU_BUSY_OVERRIDE env
// value (0..1) short-circuits real sampling for tests / forcing the path;
// otherwise take a live sample.
async function resolveCpuBusyFraction() {
  const raw = process.env.CODEX_WORKFLOW_CPU_BUSY_OVERRIDE;
  if (raw !== undefined && raw !== '') {
    const v = Number(raw);
    if (Number.isFinite(v)) return Math.max(0, Math.min(1, v));
  }
  return sampleCpuBusyFraction(CPU_SAMPLE_MS);
}

// --------------------------------------------------------------------- runner

async function buildRuntime(cli) {
  const runId = `wf-${new Date().toISOString().replace(/[:.]/g, '-')}-${process.pid}`;
  const runDir = path.resolve(cli.runDir || path.join(HQ_ROOT, 'workspace', 'tmp', 'codex-workflow', runId));
  fs.mkdirSync(runDir, { recursive: true });

  // A zero/negative concurrency would deadlock every agent() in acquire()
  // before its timeout is even armed, so invalid values fail fast instead.
  const positiveInt = (raw, name) => {
    if (raw === undefined || raw === null || raw === '') return null;
    const n = Number(raw);
    if (!Number.isFinite(n) || n < 1) {
      process.stderr.write(`codex-workflow: ${name} must be a positive integer, got ${JSON.stringify(raw)}\n`);
      process.exit(2);
    }
    return Math.floor(n);
  };
  const defaultConcurrency = Math.min(16, Math.max(1, os.cpus().length - 2));
  let concurrency = positiveInt(cli.concurrency, '--concurrency')
    ?? positiveInt(process.env.CODEX_WORKFLOW_CONCURRENCY, 'CODEX_WORKFLOW_CONCURRENCY')
    ?? defaultConcurrency;

  // CPU governor: check load before committing to the concurrency. Under heavy
  // CPU pressure, spawning the full fan-out of codex processes just thrashes
  // the box and slows every agent, so halve the concurrency (floor 1) and warn.
  // Applies to whatever concurrency was resolved (CLI, env, or default); opt
  // out entirely with CODEX_WORKFLOW_CPU_CHECK=0. The warning itself is emitted
  // once the narrator/journal exist, below.
  let cpuThrottle = null;
  if (CPU_CHECK_ENABLED && concurrency > 1) {
    const busy = await resolveCpuBusyFraction();
    if (busy !== null && busy >= CPU_HIGH_THRESHOLD) {
      const reduced = Math.max(1, Math.floor(concurrency / 2));
      if (reduced < concurrency) {
        cpuThrottle = { busy, from: concurrency, to: reduced };
        concurrency = reduced;
      }
    }
  }

  const defaultTimeoutSecs = positiveInt(cli.timeoutSecs, '--timeout')
    ?? positiveInt(process.env.CODEX_TIMEOUT_SECS, 'CODEX_TIMEOUT_SECS')
    ?? 1800;

  const state = {
    runDir,
    concurrency,
    semaphore: new Semaphore(concurrency),
    counter: 0,
    currentPhase: '',
    defaultTimeoutSecs,
    quiet: cli.quiet,
    activeChildren: new Set(),
    journalFile: path.join(runDir, 'journal.jsonl'),
    aborted: false,
    onAllChildrenGone: null,
  };

  const narr = (msg) => {
    if (!state.quiet) process.stderr.write(`[${hhmmss()}] ${msg}\n`);
  };

  const journal = (entry) => {
    fs.appendFileSync(state.journalFile, JSON.stringify({ ts: new Date().toISOString(), ...entry }) + '\n');
  };

  // High-CPU throttle warning: surfaced on stderr even under --quiet, since
  // reduced concurrency is an operational signal the operator should see.
  if (cpuThrottle) {
    const pct = Math.round(cpuThrottle.busy * 100);
    const thr = Math.round(CPU_HIGH_THRESHOLD * 100);
    process.stderr.write(
      `[${hhmmss()}] WARNING: high CPU usage (${pct}% >= ${thr}%) — concurrency reduced ` +
      `from ${cpuThrottle.from} to ${cpuThrottle.to}\n`);
    journal({ event: 'cpu-throttle', busy: cpuThrottle.busy, threshold: CPU_HIGH_THRESHOLD, from: cpuThrottle.from, to: cpuThrottle.to });
  }

  async function agent(prompt, opts = {}) {
    if (typeof prompt !== 'string' || !prompt.trim()) {
      throw new Error('agent() requires a non-empty string prompt');
    }
    const n = ++state.counter;
    if (n > MAX_AGENTS) throw new Error(`agent cap reached (${MAX_AGENTS})`);
    const label = opts.label || `agent-${n}`;
    // Every worker must pick a tier so the orchestrator's model choice is
    // explicit: "sol" for analysis/planning, "terra" for execution.
    const tier = opts.tier;
    if (tier !== 'sol' && tier !== 'terra') {
      throw new Error(
        `agent() requires opts.tier to be one of ${JSON.stringify(VALID_TIERS)} — ` +
        `got ${JSON.stringify(tier)} for "${label}". Use "sol" for analysis & ` +
        `planning (gpt-5.6-sol) and "terra" for execution (gpt-5.6-terra).`);
    }
    const phaseName = opts.phase || state.currentPhase;
    const timeoutSecs = opts.timeoutSecs || state.defaultTimeoutSecs;
    const logFile = path.join(state.runDir, `agent-${n}.log`);
    const lastFile = path.join(state.runDir, `agent-${n}.last.md`);

    // Working directory: every agent is launched at the HQ root, full stop.
    // Codex reads its project config — and therefore HQ's [hooks] block — from
    // the directory given to -C, and the HQ root is the only directory that
    // carries it. Anchoring an agent at a worktree instead silently drops every
    // PreToolUse safety rail. So opts.cd never reaches -C: it names the folder
    // the TASK lives in, is required to resolve inside the HQ root, and is
    // handed to the agent as a working-directory preamble on the prompt.
    const explicitCd = opts.cd !== undefined && opts.cd !== null && String(opts.cd) !== '';
    // No opts.cd -> inherit the runner's cwd, so a plan launched from inside a
    // worktree keeps pointing there (it just arrives via the prompt now).
    let workDir = path.resolve(explicitCd ? String(opts.cd) : process.cwd());
    const rel = path.relative(HQ_ROOT, workDir);
    if (rel.startsWith('..') || path.isAbsolute(rel)) {
      if (explicitCd) {
        throw new Error(
          `agent() opts.cd must resolve inside the HQ root (${HQ_ROOT}) — got ` +
          `${workDir} for "${label}". Subagents always spawn with -C ${HQ_ROOT} ` +
          `so HQ's codex hooks load; put the worktree path in opts.cd (it is ` +
          `injected into the prompt) or in the prompt itself.`);
      }
      // An inherited cwd outside HQ is the launcher's doing, not the plan's —
      // fall back to the HQ root rather than failing every agent in the run.
      narr(`! cwd ${workDir} is outside the HQ root — "${label}" targets ${HQ_ROOT} instead`);
      workDir = HQ_ROOT;
    }
    const spawnPrompt = workDir === HQ_ROOT ? prompt : [
      `Working directory for this task: ${workDir}`,
      '',
      `You are launched at the HQ root (${HQ_ROOT}) so HQ's codex hooks and safety`,
      'rails load. Do the work under the path above, not at the HQ root: cd into it',
      'for reads, builds and tests, anchor every git mutation with',
      `\`git -C ${workDir} ...\` and every GitHub mutation with \`gh ... -R owner/repo\`.`,
      '',
      '---',
      '',
      prompt,
    ].join('\n');

    const argv = ['exec', ...MANDATED_FLAGS, '--color', 'never',
      '-C', HQ_ROOT,
      '--output-last-message', lastFile];
    // Model precedence: explicit opts.model > global CODEX_WORKFLOW_MODEL pin >
    // the tier-derived model. tier is required, so there is always a model.
    let model;
    if (opts.model !== undefined) model = opts.model;
    else if (MODEL_OVERRIDE !== undefined) model = MODEL_OVERRIDE;
    else model = TIER_MODELS[tier];
    if (model) argv.push('-m', String(model));
    const effort = opts.effort !== undefined ? opts.effort : DEFAULT_EFFORT;
    if (effort) argv.push('-c', `model_reasoning_effort=${JSON.stringify(String(effort))}`);
    // Fast mode precedence: explicit opts.fastMode > CODEX_WORKFLOW_FAST_MODE >
    // the per-tier default (terra on, sol off).
    let fastMode;
    if (opts.fastMode !== undefined) fastMode = Boolean(opts.fastMode);
    else if (FAST_MODE_ENV !== undefined) fastMode = FAST_MODE_ENV;
    else fastMode = FAST_MODE_TIER_DEFAULTS[tier];
    if (fastMode) argv.push(...FAST_MODE_FLAGS);
    if (opts.schema) {
      const schemaFile = path.join(state.runDir, `agent-${n}.schema.json`);
      fs.writeFileSync(schemaFile, JSON.stringify(opts.schema, null, 2));
      argv.push('--output-schema', schemaFile);
    }
    if (Array.isArray(opts.extraArgs)) argv.push(...opts.extraArgs.map(String));
    // `--` ends option/subcommand parsing: without it a prompt like 'help' or
    // 'resume ...' is swallowed as a `codex exec` subcommand, and a prompt
    // starting with '-' is parsed as a flag.
    argv.push('--', spawnPrompt);

    if (state.aborted) throw new Error('workflow aborted by signal');
    await state.semaphore.acquire();
    const startedAt = Date.now();
    narr(`${phaseName ? `[${phaseName}] ` : ''}▶ ${label} started (warn-after ${timeoutSecs}s, log ${logFile})`);
    journal({ event: 'agent-start', n, label, phase: phaseName, timeoutSecs, logFile, lastFile, spawnCwd: HQ_ROOT, workDir, promptHead: prompt.slice(0, 200) });

    try {
      const result = await new Promise((resolve, reject) => {
        const logFd = fs.openSync(logFile, 'w');
        // A failed spawn (e.g. ENOENT) emits BOTH 'error' and 'close' — settle
        // and close the fd exactly once or the second event throws EBADF.
        let settled = false;
        let fdClosed = false;
        const settle = (err) => {
          if (!fdClosed) {
            fdClosed = true;
            try { fs.closeSync(logFd); } catch { /* already closed */ }
          }
          if (settled) return;
          settled = true;
          if (err) reject(err); else resolve(null);
        };
        let child;
        try {
          // stdin: 'ignore' wires the child's stdin to /dev/null — codex exec
          // hangs on a stdin-EOF wait otherwise (hq-codex-run-close-stdin).
          // detached: the child leads its own process group so killTree() can
          // take down codex and every subprocess codex spawned.
          child = spawn(CODEX_BIN, argv, { stdio: ['ignore', logFd, logFd], detached: true });
        } catch (e) {
          settle(new Error(`failed to spawn ${CODEX_BIN}: ${errMsg(e)}`));
          return;
        }
        state.activeChildren.add(child);
        // Soft timeout: never kills. Each time the timeout interval elapses,
        // print a TIMEOUT WARNING to stdout (even under --quiet — it is the
        // signal the orchestrator watches) so it can decide whether to kill
        // the process group or let the agent continue.
        const warnTimer = setInterval(() => {
          const elapsed = Math.round((Date.now() - startedAt) / 1000);
          process.stdout.write(
            `[${hhmmss()}] TIMEOUT WARNING: ${label} still running after ${elapsed}s ` +
            `(timeout ${timeoutSecs}s, pid ${child.pid}) — not killed; ` +
            `kill -- -${child.pid} to stop it, or let it continue. Log: ${logFile}\n`);
          journal({ event: 'agent-timeout-warning', n, label, phase: phaseName, elapsed, timeoutSecs, pid: child.pid });
        }, timeoutSecs * 1000);
        child.on('error', (e) => {
          clearInterval(warnTimer);
          state.activeChildren.delete(child);
          settle(new Error(`failed to spawn ${CODEX_BIN}: ${errMsg(e)}`));
        });
        child.on('close', (code, signal) => {
          clearInterval(warnTimer);
          state.activeChildren.delete(child);
          if (state.aborted && state.activeChildren.size === 0 && state.onAllChildrenGone) {
            state.onAllChildrenGone();
          }
          if (state.aborted) {
            settle(new Error(`workflow aborted by signal (${label} terminated)`));
          } else if (code !== 0) {
            settle(new Error(`${label} exited with code=${code} signal=${signal ?? 'none'}. Log: ${logFile}\n--- log tail ---\n${tailOfFile(logFile, 600)}`));
          } else {
            settle(null);
          }
        });
      }).then(() => {
        // Final message comes from the dedicated --output-last-message file,
        // never from tailing the transcript (large-output-relay policy).
        let text;
        try {
          text = fs.readFileSync(lastFile, 'utf8');
        } catch {
          throw new Error(`${label} exited 0 but wrote no last-message file (${lastFile}). Log: ${logFile}`);
        }
        return opts.schema ? parseMaybeJson(text, `${label}, raw text in ${lastFile}`) : text.trim();
      });

      const secs = Math.round((Date.now() - startedAt) / 1000);
      narr(`${phaseName ? `[${phaseName}] ` : ''}✔ ${label} done (${secs}s)`);
      journal({ event: 'agent-done', n, label, phase: phaseName, secs });
      return result;
    } catch (e) {
      const secs = Math.round((Date.now() - startedAt) / 1000);
      narr(`${phaseName ? `[${phaseName}] ` : ''}✖ ${label} FAILED (${secs}s): ${errMsg(e).split('\n')[0]}`);
      journal({ event: 'agent-fail', n, label, phase: phaseName, secs, error: errMsg(e) });
      throw e;
    } finally {
      state.semaphore.release();
    }
  }

  async function parallel(thunks) {
    if (!Array.isArray(thunks)) throw new Error('parallel() takes an array of thunks');
    return Promise.all(thunks.map(async (thunk, i) => {
      try {
        return await thunk();
      } catch (e) {
        narr(`parallel[${i}] resolved to null: ${errMsg(e).split('\n')[0]}`);
        return null;
      }
    }));
  }

  async function pipeline(items, ...stages) {
    if (!Array.isArray(items)) throw new Error('pipeline() takes an array of items');
    return Promise.all(items.map(async (item, i) => {
      let acc = item;
      for (let s = 0; s < stages.length; s++) {
        try {
          acc = await stages[s](acc, item, i);
        } catch (e) {
          narr(`pipeline item[${i}] dropped at stage ${s + 1}: ${errMsg(e).split('\n')[0]}`);
          return null;
        }
      }
      return acc;
    }));
  }

  function phase(title) {
    state.currentPhase = String(title);
    narr(`━━ phase: ${title}`);
    journal({ event: 'phase', title: String(title) });
  }

  function log(msg) {
    narr(String(msg));
    journal({ event: 'log', msg: String(msg) });
  }

  // Token spend is not tracked for Codex runs — behave like "no target set".
  const budget = { total: null, spent: () => 0, remaining: () => Infinity };

  // ---------------------------------------------------------------- gate()
  // Human-in-the-loop pause. The run stays alive and resumes IN PLACE when an
  // answer file lands; nothing is re-run because nothing exited. The pending
  // file is self-contained (question + options + context + answer command) so
  // any session — not just the launcher — can answer it cold.
  const scriptName = cli.scriptPath ? path.resolve(cli.scriptPath) : '<eval>';

  const slugifyGateId = (raw) => String(raw ?? '')
    .trim().toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '-')
    .replace(/^[-._]+|[-._]+$/g, '');

  async function gate(id, question, opts = {}) {
    const gid = slugifyGateId(id);
    if (!gid) {
      throw new Error(`gate() requires an id with at least one [a-z0-9._-] character after slugging — got ${JSON.stringify(id)}`);
    }
    if (typeof question !== 'string' || !question.trim()) {
      throw new Error(`gate() requires a non-empty question string for "${gid}"`);
    }
    const options = Array.isArray(opts.options)
      ? opts.options.map((o) => (typeof o === 'string'
        ? { label: o }
        : { label: String(o.label), ...(o.description ? { description: String(o.description) } : {}) }))
      : [];
    const pollSecs = Number(opts.pollSecs) > 0 ? Number(opts.pollSecs) : DEFAULT_GATE_POLL_SECS;
    const pendingDir = path.join(GATES_DIR, 'pending');
    const answeredDir = path.join(GATES_DIR, 'answered');
    fs.mkdirSync(pendingDir, { recursive: true });
    fs.mkdirSync(answeredDir, { recursive: true });
    const pendingFile = path.join(pendingDir, `${gid}.json`);
    const answerFile = path.join(answeredDir, `${gid}.json`);

    // A half-written or garbage answer file must not crash the wait — treat it
    // as "not answered yet" and pick up the next valid write (the answer
    // helper writes tmp+rename, but hand-written answers may not).
    const readAnswer = () => {
      try { return JSON.parse(fs.readFileSync(answerFile, 'utf8')); } catch { return null; }
    };

    // Durable answers: an already-answered gate returns instantly, so a
    // re-launched run sails through every decision a human already made.
    const cached = readAnswer();
    if (cached) {
      try { fs.rmSync(pendingFile, { force: true }); } catch { /* best-effort */ }
      process.stdout.write(`[${hhmmss()}] GATE CACHED: ${gid} → ${cached.choice ?? '<no choice>'} (${answerFile})\n`);
      journal({ event: 'gate-cached', id: gid, choice: cached.choice ?? null });
      return cached;
    }

    const payload = {
      id: gid,
      question: question.trim(),
      options,
      ...(opts.context ? { context: String(opts.context) } : {}),
      ...(opts.recommended ? { recommended: String(opts.recommended) } : {}),
      status: 'pending',
      created_at: new Date().toISOString(),
      run_id: runId,
      run_dir: state.runDir,
      script: scriptName,
      answer_path: answerFile,
      answer_hint: `bash core/scripts/workflow-gate.sh answer ${gid} "<choice|N>" [--notes "..."]`,
    };
    const tmp = `${pendingFile}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n');
    fs.renameSync(tmp, pendingFile);
    // GATE OPEN goes to stdout even under --quiet — like TIMEOUT WARNING, it
    // is the signal a watching orchestrator acts on.
    process.stdout.write(
      `[${hhmmss()}] GATE OPEN: ${gid} — ${question.trim()} ` +
      `(answer: bash core/scripts/workflow-gate.sh answer ${gid} "<choice|N>"; pending: ${pendingFile})\n`);
    journal({ event: 'gate-open', id: gid, question: question.trim(), pendingFile });
    narr(`⏸ gate open: ${gid} — paused for a human answer (poll ${pollSecs}s)`);

    const startedAt = Date.now();
    for (;;) {
      if (state.aborted) throw new Error(`workflow aborted by signal (gate ${gid} still pending)`);
      const answer = readAnswer();
      if (answer) {
        try { fs.rmSync(pendingFile, { force: true }); } catch { /* best-effort */ }
        const waitedSecs = Math.round((Date.now() - startedAt) / 1000);
        process.stdout.write(`[${hhmmss()}] GATE ANSWERED: ${gid} → ${answer.choice ?? '<no choice>'} (waited ${waitedSecs}s)\n`);
        journal({ event: 'gate-answered', id: gid, choice: answer.choice ?? null, waitedSecs });
        narr(`▶ gate answered: ${gid} — resuming`);
        return answer;
      }
      await new Promise((resolve) => setTimeout(resolve, pollSecs * 1000));
    }
  }

  return { state, narr, journal, agent, parallel, pipeline, phase, log, budget, gate };
}

// ------------------------------------------------------------- script loading

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const SCRIPT_PARAMS = ['agent', 'parallel', 'pipeline', 'phase', 'log', 'args', 'budget', 'workflow', 'gate'];

function compileScript(source, name) {
  // Try the source verbatim first: inside a function body a real top-level
  // `export`/`import` is a SyntaxError, but the same words inside a
  // template-literal prompt are data and must never be rewritten.
  try {
    return new AsyncFunction(...SCRIPT_PARAMS, source);
  } catch (primaryErr) {
    // Workflow-tool shape: strip top-level `export` keywords
    // (`export const meta = {...}` -> `const meta = {...}`) and retry.
    const transformed = source.replace(/^(\s*)export\s+(?=(const|let|var|function|async|class)\b)/gm, '$1');
    try {
      return new AsyncFunction(...SCRIPT_PARAMS, transformed);
    } catch {
      throw new Error(`${name}: script failed to parse: ${errMsg(primaryErr)} (static import and export default are not supported; Workflow-tool scripts with "export const meta" are)`);
    }
  }
}

// Set once buildRuntime() has run so shutdown paths (signals, fatal errors)
// can always reach the active children.
let RT = null;

// Terminate every in-flight codex process group, then exit with `code` — the
// exit is guaranteed: immediately when no children remain, as soon as the last
// child is reaped, or after a 5s ref'd fallback timer (TERM first, KILL late).
// A second signal skips straight to SIGKILL.
function terminateAndExit(code) {
  if (!RT) process.exit(code);
  const st = RT.state;
  if (st.aborted) {
    for (const child of st.activeChildren) killTree(child, 'SIGKILL');
    process.exit(code);
  }
  st.aborted = true;
  for (const child of st.activeChildren) killTree(child, 'SIGTERM');
  if (st.activeChildren.size === 0) process.exit(code);
  st.onAllChildrenGone = () => process.exit(code);
  setTimeout(() => {
    for (const child of st.activeChildren) killTree(child, 'SIGKILL');
    process.exit(code);
  }, 5000);
}

async function main() {
  const cli = parseCli(process.argv.slice(2));
  const rt = await buildRuntime(cli);
  RT = rt;

  // Kill in-flight codex process trees on Ctrl-C / TERM instead of orphaning
  // them — and never let a caught agent failure turn the abort into exit 0.
  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
      rt.narr(`received ${sig} — terminating ${rt.state.activeChildren.size} codex process(es)`);
      terminateAndExit(130);
    });
  }

  let workflowDepth = 0;
  async function workflow(ref, childArgs) {
    if (workflowDepth >= 1) throw new Error('workflow() nesting is one level only');
    const scriptPath = typeof ref === 'string' ? ref : ref && ref.scriptPath;
    if (!scriptPath) throw new Error('workflow() needs a script path string or {scriptPath}');
    const resolved = path.resolve(scriptPath);
    const source = fs.readFileSync(resolved, 'utf8');
    const fn = compileScript(source, resolved);
    rt.narr(`▸ nested workflow: ${resolved}`);
    workflowDepth++;
    try {
      return await fn(rt.agent, rt.parallel, rt.pipeline, rt.phase, rt.log, childArgs, rt.budget, () => {
        throw new Error('workflow() nesting is one level only');
      }, rt.gate);
    } finally {
      workflowDepth--;
    }
  }

  const name = cli.scriptPath ? path.resolve(cli.scriptPath) : '<eval>';
  const source = cli.scriptPath ? fs.readFileSync(name, 'utf8') : cli.evalSrc;
  const fn = compileScript(source, name);

  rt.narr(`run dir: ${rt.state.runDir}`);
  rt.journal({ event: 'run-start', script: name, argsProvided: cli.args !== undefined, concurrency: rt.state.concurrency });

  const result = await fn(rt.agent, rt.parallel, rt.pipeline, rt.phase, rt.log, cli.args, rt.budget, workflow, rt.gate);

  rt.journal({ event: 'run-done', agents: rt.state.counter });
  rt.narr(`done — ${rt.state.counter} agent(s), artifacts in ${rt.state.runDir}`);
  process.stdout.write(JSON.stringify(result ?? null, null, 2) + '\n');
}

main().catch((e) => {
  process.stderr.write(`codex-workflow: FAILED: ${errMsg(e)}\n`);
  // A fatal script error must not orphan still-running codex agents.
  terminateAndExit(1);
});
