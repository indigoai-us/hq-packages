/**
 * Secure capability-bridge sidecar — reference implementation.
 *
 * This module is intentionally a small, explicit dispatcher. Remote messages
 * may request named capabilities, but they never get a shell, arbitrary file
 * reads, or access outside an explicit allowlist. It is standalone and
 * dependency-free (Node fs/os/path only) and config-driven — pass it the tree
 * root, allowed roots, deny lists, and an audit-log path. Copy it into your
 * project and adapt the capability handlers to your domain.
 *
 * Generalized from a NanoClaw "HQ sidecar" spike. No host-specific paths are
 * hardcoded here — everything tree-specific comes from `BridgeConfig`.
 *
 * Runs under `npx tsx` or `bun`. No build step required.
 */
import fs from 'fs';
import os from 'os';
import path from 'path';

export type ReadCapability = 'read_status' | 'lookup' | 'search';
export type MutationCapability = 'create_record';
export type Capability = ReadCapability | MutationCapability;

export type Outcome = 'allowed' | 'completed' | 'denied' | 'failed';
export type ConfirmationState = 'none' | 'pending' | 'confirmed' | 'cancelled' | 'expired';
export type RiskLevel = 'low' | 'medium' | 'high';

export interface Requester {
  id: string;
  displayName?: string;
}

export interface BridgeRequest {
  capability?: string;
  action?: string;
  requester?: string | Requester;
  channel?: string;
  scope?: string;
  query?: string;
  /** Plain safe path segment naming a record under an allowed root. */
  name?: string;
  /** Confirmation phrase supplied by the caller for a mutation. */
  confirmation?: string;
  confirmationState?: ConfirmationState;
  /** Free-text payload for a mutation record. */
  title?: string;
  summary?: string;
  body?: string;
}

export interface AllowedRoot {
  /** Path relative to `treeRoot`. */
  path: string;
  access: 'read' | 'read-write';
}

export interface BridgeConfig {
  /** Absolute path to the sensitive tree. Supports a leading `~`. */
  treeRoot: string;
  /** Explicit allowlist. Each entry is a path relative to `treeRoot`. */
  allowedRoots: AllowedRoot[];
  /** Substrings that, if present in a requested path/query, force a denial. */
  deniedPathPatterns: string[];
  /** Words that, if present in the capability/action, force a denial. */
  deniedActionWords: string[];
  /** Relative root searched by `read_status` (most-recent files). */
  statusRoot: string;
  /** Relative read-write root where `create_record` writes its record. */
  mutationScope: string;
  /** Exact phrase required to execute `create_record`. */
  createRecordConfirmationPhrase: string;
  /** Where the append-only JSONL audit log is written (absolute). */
  auditLogPath: string;
  maxFileBytes?: number;
  maxResults?: number;
  now?: () => Date;
}

export interface Source {
  path: string;
  title?: string;
  line?: number;
  excerpt?: string;
}

export interface AuditEntry {
  timestamp: string;
  requester: string;
  channel: string;
  capability: string;
  scope: string | null;
  confirmationState: ConfirmationState;
  outcome: Outcome;
  filesRead: string[];
  filesWritten: string[];
  denialReason?: string;
  error?: string;
}

export interface MutationEnvelope {
  capability: MutationCapability;
  summary: string;
  targetScope: string;
  affectedPaths: string[];
  riskLevel: RiskLevel;
  confirmationPhrase: string;
}

export interface BridgeResponse {
  ok: boolean;
  capability: string;
  outcome: Outcome;
  message: string;
  sources: Source[];
  filesRead: string[];
  filesWritten: string[];
  audit: AuditEntry;
  denialReason?: string;
  mutation?: MutationEnvelope;
}

const READ_CAPABILITIES = new Set<string>(['read_status', 'lookup', 'search']);
const MUTATION_CAPABILITIES = new Set<string>(['create_record']);
const SEARCH_EXTENSIONS = new Set(['.json', '.md', '.txt', '.yaml', '.yml']);
const DEFAULT_MAX_FILE_BYTES = 256 * 1024;
const DEFAULT_MAX_RESULTS = 5;

interface Ctx {
  config: Required<Pick<BridgeConfig, 'maxFileBytes' | 'maxResults'>> & BridgeConfig;
  treeRoot: string;
  allowedRoots: string[]; // resolved absolute
  filesRead: Set<string>;
  sources: Source[];
}

/** Build a bridge bound to a config. Returns an evaluator function. */
export function createBridge(config: BridgeConfig) {
  return (request: BridgeRequest) => evaluateCapability(request, config);
}

export async function evaluateCapability(request: BridgeRequest, config: BridgeConfig): Promise<BridgeResponse> {
  const now = config.now ?? (() => new Date());
  const treeRoot = path.resolve(expandHome(config.treeRoot));
  const ctx: Ctx = {
    config: {
      ...config,
      maxFileBytes: config.maxFileBytes ?? DEFAULT_MAX_FILE_BYTES,
      maxResults: config.maxResults ?? DEFAULT_MAX_RESULTS,
    },
    treeRoot,
    allowedRoots: config.allowedRoots.map((root) => path.resolve(treeRoot, root.path)),
    filesRead: new Set<string>(),
    sources: [],
  };

  const capability = String(request.capability ?? request.action ?? '').trim();
  const requester = normalizeRequester(request.requester);
  const channel = cleanLabel(request.channel) || 'unknown';
  const scope = cleanScope(request.scope ?? request.name ?? request.query ?? null);
  let confirmationState = request.confirmationState ?? 'none';
  let response: Omit<BridgeResponse, 'audit'>;

  try {
    const denialReason = classifyDenial(request, capability, ctx);
    if (denialReason) {
      response = deniedResponse(capability || 'unknown', denialReason, ctx);
    } else if (MUTATION_CAPABILITIES.has(capability)) {
      const mutation = buildMutationEnvelope(capability as MutationCapability, request, ctx, now());
      if (confirmationState === 'none') confirmationState = 'pending';

      if (confirmationState === 'pending') {
        response = pendingMutationResponse(mutation, ctx);
      } else if (confirmationState === 'confirmed') {
        const confirmation = cleanLabel(request.confirmation);
        if (confirmation !== mutation.confirmationPhrase) {
          response = deniedResponse(capability, 'Missing or invalid confirmation phrase for mutation.', ctx, {
            mutation,
          });
        } else {
          const execution = await executeMutation(mutation, request, ctx, now());
          response = completedMutationResponse(execution.message, mutation, execution.filesWritten, ctx);
        }
      } else {
        response = deniedResponse(capability, `Confirmation was ${confirmationState}; mutation not executed.`, ctx, {
          mutation,
        });
      }
    } else if (!READ_CAPABILITIES.has(capability)) {
      response = deniedResponse(
        capability || 'unknown',
        `Capability "${capability || 'unknown'}" is not enabled for this bridge.`,
        ctx,
      );
    } else {
      response = dispatchRead(capability as ReadCapability, request, ctx);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    response = {
      ok: false,
      capability: capability || 'unknown',
      outcome: 'failed',
      message: `Bridge failed while handling ${capability || 'unknown'}.`,
      sources: ctx.sources,
      filesRead: [...ctx.filesRead],
      filesWritten: [],
      denialReason: message,
    };
  }

  const audit = await writeAuditEntry(
    {
      timestamp: now().toISOString(),
      requester,
      channel,
      capability: response.capability,
      scope,
      confirmationState,
      outcome: response.outcome,
      filesRead: response.filesRead,
      filesWritten: response.filesWritten,
      ...(response.denialReason ? { denialReason: response.denialReason } : {}),
      ...(response.outcome === 'failed' && response.denialReason ? { error: response.denialReason } : {}),
    },
    ctx.config.auditLogPath,
  );

  return { ...response, audit };
}

function dispatchRead(capability: ReadCapability, request: BridgeRequest, ctx: Ctx): Omit<BridgeResponse, 'audit'> {
  if (capability === 'read_status') return readStatus(ctx);
  if (capability === 'lookup') return lookup(request, ctx);
  return search(request, ctx);
}

function readStatus(ctx: Ctx): Omit<BridgeResponse, 'audit'> {
  const files = newestFiles(resolveAllowed(ctx, ctx.config.statusRoot), ctx, 5);
  const lines = files.map((file) => {
    const parsed = file.endsWith('.json') ? readJson(file, ctx) : readText(file, ctx);
    if (isRecord(parsed)) {
      const title = valueAt(parsed, ['title']) ?? valueAt(parsed, ['name']) ?? path.basename(file);
      const summary = valueAt(parsed, ['summary']) ?? valueAt(parsed, ['status']) ?? '';
      return `${String(title)}${summary ? `: ${truncate(String(summary), 180)}` : ''}`;
    }
    return firstHeadingOrLine(String(parsed));
  });
  return allowedResponse('read_status', lines.length ? lines.join(' ') : 'No status files found.', ctx);
}

function lookup(request: BridgeRequest, ctx: Ctx): Omit<BridgeResponse, 'audit'> {
  const name = request.name ?? request.query ?? request.scope;
  if (!name) return deniedResponse('lookup', 'Lookup requires an explicit record name.', ctx);

  const segment = sanitizePathSegment(String(name));
  // Search each allowed root for a file or directory matching the segment.
  for (const root of ctx.allowedRoots) {
    const direct = path.join(root, segment);
    if (isAllowedResolvedPath(direct, ctx) && fs.existsSync(direct)) {
      const stat = fs.statSync(direct);
      if (stat.isFile()) {
        const text = readText(direct, ctx);
        return allowedResponse('lookup', firstHeadingOrLine(text), ctx);
      }
      if (stat.isDirectory()) {
        const inside = newestFiles(direct, ctx, 1)[0];
        if (inside) {
          const text = readText(inside, ctx);
          return allowedResponse('lookup', firstHeadingOrLine(text), ctx);
        }
      }
    }
  }
  return allowedResponse('lookup', `No allowlisted record matched "${cleanLabel(name)}".`, ctx);
}

function search(request: BridgeRequest, ctx: Ctx): Omit<BridgeResponse, 'audit'> {
  const query = request.query?.trim();
  if (!query) return deniedResponse('search', 'Search requires a non-empty query.', ctx);
  if (!request.scope) return deniedResponse('search', 'Search requires an explicit allowed scope.', ctx);

  const rootsOrDenial = resolveScope(request.scope, ctx);
  if (typeof rootsOrDenial === 'string') return deniedResponse('search', rootsOrDenial, ctx);

  const matches = searchFiles(rootsOrDenial, query, ctx);
  return {
    ok: true,
    capability: 'search',
    outcome: 'allowed',
    message: matches.length
      ? `Found ${matches.length} result${matches.length === 1 ? '' : 's'} for "${cleanLabel(query)}".`
      : `No results matched "${cleanLabel(query)}".`,
    sources: matches.map((m) => m.source),
    filesRead: [...ctx.filesRead],
    filesWritten: [],
  };
}

/** Resolve a caller-supplied scope to allowlisted roots, or return a denial string. */
function resolveScope(scope: string, ctx: Ctx): string[] | string {
  const clean = scope.trim();
  const candidate = path.resolve(ctx.treeRoot, clean);
  if (isAllowedResolvedPath(candidate, ctx) && fs.existsSync(candidate)) return [candidate];
  return `Scope "${cleanLabel(scope)}" is not allowlisted for search.`;
}

// ---- mutations ----

function buildMutationEnvelope(
  capability: MutationCapability,
  request: BridgeRequest,
  ctx: Ctx,
  now: Date,
): MutationEnvelope {
  const relativePath = path.posix.join(ctx.config.mutationScope, `record-${timestampSlug(now)}.json`);
  return {
    capability,
    summary:
      cleanText(request.summary, 240) ||
      cleanText(request.title, 160) ||
      cleanText(request.query, 240) ||
      'Create a request record.',
    targetScope: ctx.config.mutationScope,
    affectedPaths: [relativePath],
    riskLevel: 'low',
    confirmationPhrase: ctx.config.createRecordConfirmationPhrase,
  };
}

async function executeMutation(
  mutation: MutationEnvelope,
  request: BridgeRequest,
  ctx: Ctx,
  now: Date,
): Promise<{ filesWritten: string[]; message: string }> {
  const target = path.resolve(ctx.treeRoot, mutation.affectedPaths[0] ?? '');
  assertMutationTarget(target, ctx);

  const payload = {
    id: `record-${timestampSlug(now)}`,
    createdAt: now.toISOString(),
    source: 'secure-sidecar',
    capability: mutation.capability,
    targetScope: mutation.targetScope,
    summary: mutation.summary,
    title: cleanText(request.title, 120),
    body: cleanText(request.body, 2000) || cleanText(request.query, 2000) || '',
  };

  await fs.promises.mkdir(path.dirname(target), { recursive: true });
  // `wx` flag: fail rather than overwrite an existing file.
  await fs.promises.writeFile(target, `${JSON.stringify(payload, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });

  return {
    filesWritten: mutation.affectedPaths,
    message: `Completed ${mutation.capability}; wrote ${mutation.affectedPaths[0]}.`,
  };
}

function assertMutationTarget(target: string, ctx: Ctx): void {
  const scopeRoot = path.resolve(ctx.treeRoot, ctx.config.mutationScope);
  const relative = path.relative(scopeRoot, target);
  if (relative.startsWith('..') || path.isAbsolute(relative) || !relative.endsWith('.json')) {
    throw new Error('Mutations can only write JSON records inside the configured mutation scope.');
  }
}

// ---- safety machinery (load-bearing — keep) ----

function classifyDenial(request: BridgeRequest, capability: string, ctx: Ctx): string | null {
  const actionText = `${capability} ${request.action ?? ''}`.toLowerCase();
  if (ctx.config.deniedActionWords.some((word) => actionText.includes(word.toLowerCase()))) {
    return 'Arbitrary shell, tool, git, deploy, install, publish, and external mutation actions are not enabled.';
  }
  const pathText = [request.scope, request.query, request.name]
    .filter((v): v is string => typeof v === 'string')
    .join(' ')
    .toLowerCase();
  if (pathText && matchesDeniedPath(pathText, ctx)) {
    return 'The requested path or query names a denied credential, settings, or broad source path.';
  }
  return null;
}

function matchesDeniedPath(input: string, ctx: Ctx): boolean {
  const normalized = input.replace(/\\/g, '/').toLowerCase();
  return ctx.config.deniedPathPatterns.some((pattern) => {
    const lower = pattern.toLowerCase().replace(/\*/g, '');
    return lower && normalized.includes(lower);
  });
}

function resolveAllowed(ctx: Ctx, relativePath: string): string {
  const resolved = path.resolve(ctx.treeRoot, relativePath);
  if (!isAllowedResolvedPath(resolved, ctx)) {
    throw new Error(`Path "${relativePath}" is not allowlisted for this bridge.`);
  }
  return resolved;
}

function isAllowedResolvedPath(candidate: string, ctx: Ctx): boolean {
  const resolved = path.resolve(candidate);
  const relative = path.relative(ctx.treeRoot, resolved);
  if (relative.startsWith('..') || path.isAbsolute(relative)) return false;
  if (matchesDeniedPath(relative, ctx)) return false;
  return ctx.allowedRoots.some((allowed) => {
    const rootRelative = path.relative(allowed, resolved);
    return rootRelative === '' || (!rootRelative.startsWith('..') && !path.isAbsolute(rootRelative));
  });
}

function readText(file: string, ctx: Ctx): string {
  if (!isAllowedResolvedPath(file, ctx)) throw new Error(`Denied read for ${relativeToTree(file, ctx)}.`);
  const stat = fs.statSync(file);
  if (stat.size > ctx.config.maxFileBytes) throw new Error(`Refusing to read large file ${relativeToTree(file, ctx)}.`);
  const text = fs.readFileSync(file, 'utf8');
  recordRead(file, ctx);
  return text;
}

function readJson(file: string, ctx: Ctx): unknown {
  try {
    return JSON.parse(readText(file, ctx)) as unknown;
  } catch {
    return {};
  }
}

function recordRead(file: string, ctx: Ctx): void {
  const relative = relativeToTree(file, ctx);
  ctx.filesRead.add(relative);
  if (!ctx.sources.some((s) => s.path === relative)) {
    ctx.sources.push({ path: relative, title: path.basename(file) });
  }
}

function searchFiles(roots: string[], query: string, ctx: Ctx): { source: Source; score: number }[] {
  const terms = query
    .toLowerCase()
    .split(/\s+/)
    .map((t) => t.trim())
    .filter(Boolean);
  if (terms.length === 0) return [];

  const matches: { source: Source; score: number }[] = [];
  for (const root of roots) {
    for (const file of listSearchableFiles(root, ctx)) {
      const text = readText(file, ctx);
      const lines = text.split(/\r?\n/);
      const lowerFile = file.toLowerCase();
      const filenameScore = terms.filter((t) => lowerFile.includes(t)).length;
      for (let i = 0; i < lines.length; i += 1) {
        const lower = lines[i].toLowerCase();
        const score = terms.filter((t) => lower.includes(t)).length + filenameScore;
        if (score > 0) {
          matches.push({
            score,
            source: { path: relativeToTree(file, ctx), line: i + 1, excerpt: truncate(lines[i].trim(), 220) },
          });
          break;
        }
      }
    }
  }
  return matches.sort((a, b) => b.score - a.score).slice(0, ctx.config.maxResults);
}

function listSearchableFiles(root: string, ctx: Ctx): string[] {
  if (!fs.existsSync(root)) return [];
  const stat = fs.statSync(root);
  if (stat.isFile()) return isSearchableFile(root, ctx) ? [root] : [];
  if (!stat.isDirectory()) return [];

  const out: string[] = [];
  const stack = [root];
  while (stack.length && out.length < ctx.config.maxResults * 20) {
    const current = stack.pop();
    if (!current) continue;
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const next = path.join(current, entry.name);
      if (!isAllowedResolvedPath(next, ctx)) continue;
      if (entry.isDirectory()) stack.push(next);
      else if (entry.isFile() && isSearchableFile(next, ctx)) out.push(next);
    }
  }
  return out;
}

function isSearchableFile(file: string, ctx: Ctx): boolean {
  if (!SEARCH_EXTENSIONS.has(path.extname(file).toLowerCase())) return false;
  return fs.statSync(file).size <= ctx.config.maxFileBytes && isAllowedResolvedPath(file, ctx);
}

function newestFiles(root: string, ctx: Ctx, count: number): string[] {
  if (!fs.existsSync(root)) return [];
  return listSearchableFiles(root, ctx)
    .map((file) => ({ file, mtime: fs.statSync(file).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, count)
    .map((e) => e.file);
}

// ---- responses ----

function allowedResponse(capability: ReadCapability, message: string, ctx: Ctx): Omit<BridgeResponse, 'audit'> {
  return { ok: true, capability, outcome: 'allowed', message, sources: ctx.sources, filesRead: [...ctx.filesRead], filesWritten: [] };
}

function pendingMutationResponse(mutation: MutationEnvelope, ctx: Ctx): Omit<BridgeResponse, 'audit'> {
  return {
    ok: true,
    capability: mutation.capability,
    outcome: 'allowed',
    message: `Confirmation required for ${mutation.capability}: ${mutation.summary} Affected path: ${mutation.affectedPaths.join(', ')}. Reply exactly "${mutation.confirmationPhrase}" to continue.`,
    sources: ctx.sources,
    filesRead: [...ctx.filesRead],
    filesWritten: [],
    mutation,
  };
}

function completedMutationResponse(
  message: string,
  mutation: MutationEnvelope,
  filesWritten: string[],
  ctx: Ctx,
): Omit<BridgeResponse, 'audit'> {
  return {
    ok: true,
    capability: mutation.capability,
    outcome: 'completed',
    message,
    sources: ctx.sources,
    filesRead: [...ctx.filesRead],
    filesWritten,
    mutation,
  };
}

function deniedResponse(
  capability: string,
  denialReason: string,
  ctx: Ctx,
  options: { mutation?: MutationEnvelope } = {},
): Omit<BridgeResponse, 'audit'> {
  return {
    ok: false,
    capability,
    outcome: 'denied',
    message: `Denied by sidecar boundary: ${denialReason}`,
    sources: ctx.sources,
    filesRead: [...ctx.filesRead],
    filesWritten: [],
    denialReason,
    ...(options.mutation ? { mutation: options.mutation } : {}),
  };
}

// ---- audit ----

async function writeAuditEntry(entry: AuditEntry, auditLogPath: string): Promise<AuditEntry> {
  const target = path.resolve(expandHome(auditLogPath));
  await fs.promises.mkdir(path.dirname(target), { recursive: true });
  await fs.promises.appendFile(target, `${JSON.stringify(entry)}\n`, 'utf8');
  return entry;
}

// ---- helpers ----

function normalizeRequester(requester: string | Requester | undefined): string {
  if (typeof requester === 'string' && requester.trim()) return requester.trim();
  if (typeof requester === 'object' && requester && typeof requester.id === 'string' && requester.id.trim()) {
    return requester.displayName ? `${requester.id.trim()} (${requester.displayName.trim()})` : requester.id.trim();
  }
  return 'unknown';
}

function cleanScope(scope: string | null): string | null {
  return scope ? truncate(scope.trim(), 180) : null;
}

function cleanLabel(value: unknown): string {
  return String(value ?? '').replace(/\s+/g, ' ').trim().slice(0, 180);
}

function cleanText(value: string | undefined, max: number): string | undefined {
  if (typeof value !== 'string') return undefined;
  const clean = value.replace(/\s+/g, ' ').trim();
  return clean ? clean.slice(0, max) : undefined;
}

function sanitizePathSegment(value: string): string {
  const clean = value.trim();
  if (!/^[A-Za-z0-9._-]+$/.test(clean)) {
    throw new Error('Record and scope names must be explicit safe path segments.');
  }
  return clean;
}

function firstHeadingOrLine(text: string): string {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const heading = lines.find((l) => l.startsWith('#'));
  return truncate(heading ?? lines[0] ?? '', 220);
}

function truncate(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, Math.max(0, max - 3))}...`;
}

function valueAt(value: unknown, parts: string[]): unknown {
  let current = value;
  for (const part of parts) {
    if (!isRecord(current)) return undefined;
    current = current[part];
  }
  return current;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function relativeToTree(file: string, ctx: Ctx): string {
  return path.relative(ctx.treeRoot, path.resolve(file)).replace(/\\/g, '/');
}

function timestampSlug(now: Date): string {
  return now.toISOString().replace(/\.\d{3}Z$/, 'Z').replace(/[-:]/g, '').replace('T', '-').replace('Z', '');
}

function expandHome(input: string): string {
  if (input === '~') return os.homedir();
  if (input.startsWith('~/')) return path.join(os.homedir(), input.slice(2));
  return input;
}
