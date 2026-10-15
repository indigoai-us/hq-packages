// A small JSON Schema checker for the subset booking.schema.json uses. It has no
// dependencies so the launcher, the booking app and its API share one copy.
//
// Supported keywords: $ref (local #/$defs only), type, const, enum, properties,
// required, additionalProperties (false), items, minItems, maxItems,
// uniqueItems, minLength, maxLength, pattern, minimum, maximum, oneOf.
// An unsupported keyword in the schema throws, so the schema cannot silently
// promise a rule that nothing enforces.

export interface Issue {
  path: string;
  code: string;
  message: string;
}

type Schema = Record<string, unknown>;

const SUPPORTED = new Set([
  "$schema", "$id", "$defs", "$ref", "title", "description",
  "type", "const", "enum", "properties", "required", "additionalProperties",
  "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength",
  "pattern", "minimum", "maximum", "oneOf",
]);

export function joinPath(base: string, key: string | number): string {
  if (typeof key === "number") return `${base}[${key}]`;
  return base ? `${base}.${key}` : key;
}

function typeOf(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  if (typeof value === "number") return Number.isInteger(value) ? "integer" : "number";
  return typeof value;
}

function typeMatches(expected: string, value: unknown): boolean {
  const actual = typeOf(value);
  if (expected === "number") return actual === "number" || actual === "integer";
  return actual === expected;
}

function describe(value: unknown): string {
  const t = typeOf(value);
  return t === "integer" ? "a whole number" : t === "number" ? "a number" : t === "array" ? "a list" : t === "object" ? "a section" : t === "string" ? "text" : t;
}

const TYPE_WORDS: Record<string, string> = {
  object: "a section", array: "a list", string: "text", integer: "a whole number", number: "a number", boolean: "true or false",
};

export class SchemaChecker {
  private readonly root: Schema;
  private readonly patterns = new Map<string, RegExp>();

  constructor(root: Schema) {
    this.root = root;
    this.assertSupported(root, "#");
  }

  check(value: unknown): Issue[] {
    const issues: Issue[] = [];
    this.visit(this.root, value, "", issues);
    return issues;
  }

  private assertSupported(schema: unknown, where: string): void {
    if (!schema || typeof schema !== "object" || Array.isArray(schema)) return;
    for (const [key, child] of Object.entries(schema as Schema)) {
      if (!SUPPORTED.has(key)) throw new Error(`booking.schema.json uses unsupported keyword ${key} at ${where}`);
      if (key === "properties" || key === "$defs") {
        for (const [name, sub] of Object.entries(child as Schema)) this.assertSupported(sub, `${where}/${key}/${name}`);
      } else if (key === "items" || key === "additionalProperties") {
        this.assertSupported(child, `${where}/${key}`);
      } else if (key === "oneOf") {
        (child as unknown[]).forEach((sub, i) => this.assertSupported(sub, `${where}/oneOf/${i}`));
      }
    }
  }

  private resolve(schema: Schema): Schema {
    let current = schema;
    const seen = new Set<string>();
    while (typeof current.$ref === "string") {
      const ref = current.$ref;
      if (seen.has(ref)) throw new Error(`circular $ref ${ref}`);
      seen.add(ref);
      const match = /^#\/\$defs\/([A-Za-z0-9_]+)$/.exec(ref);
      if (!match) throw new Error(`unsupported $ref ${ref}`);
      const defs = (this.root.$defs ?? {}) as Record<string, Schema>;
      const target = defs[match[1] as string];
      if (!target) throw new Error(`missing $defs entry ${ref}`);
      const { $ref: _ignored, ...rest } = current;
      current = { ...target, ...rest };
    }
    return current;
  }

  private regex(pattern: string): RegExp {
    let re = this.patterns.get(pattern);
    if (!re) {
      re = new RegExp(pattern, "u");
      this.patterns.set(pattern, re);
    }
    return re;
  }

  private visit(rawSchema: Schema, value: unknown, path: string, issues: Issue[]): void {
    const schema = this.resolve(rawSchema);
    const where = path || "the file";

    if (schema.oneOf) {
      this.visitOneOf(schema.oneOf as Schema[], value, path, issues);
      return;
    }

    if ("const" in schema && value !== schema.const) {
      issues.push({ path, code: "wrong-value", message: `${where} must be ${JSON.stringify(schema.const)}.` });
      return;
    }

    if (Array.isArray(schema.enum) && !schema.enum.includes(value as never)) {
      issues.push({ path, code: "not-allowed", message: `${where} must be one of: ${(schema.enum as unknown[]).join(", ")}.` });
      return;
    }

    if (typeof schema.type === "string" && !typeMatches(schema.type, value)) {
      issues.push({ path, code: "wrong-type", message: `${where} must be ${TYPE_WORDS[schema.type] ?? schema.type}, not ${describe(value)}.` });
      return;
    }

    if (typeof value === "string") {
      if (typeof schema.minLength === "number" && value.length < schema.minLength) {
        issues.push({ path, code: "too-short", message: `${where} must be at least ${schema.minLength} characters.` });
      }
      if (typeof schema.maxLength === "number" && value.length > schema.maxLength) {
        issues.push({ path, code: "too-long", message: `${where} must be at most ${schema.maxLength} characters.` });
      }
      if (typeof schema.pattern === "string" && !this.regex(schema.pattern).test(value)) {
        const hint = typeof schema.description === "string" ? ` ${schema.description}` : "";
        issues.push({ path, code: "bad-format", message: `${where} has the wrong format.${hint}` });
      }
    }

    if (typeof value === "number") {
      if (typeof schema.minimum === "number" && value < schema.minimum) {
        issues.push({ path, code: "too-small", message: `${where} must be ${schema.minimum} or more.` });
      }
      if (typeof schema.maximum === "number" && value > schema.maximum) {
        issues.push({ path, code: "too-large", message: `${where} must be ${schema.maximum} or less.` });
      }
    }

    if (Array.isArray(value)) {
      if (typeof schema.minItems === "number" && value.length < schema.minItems) {
        issues.push({ path, code: "too-few", message: `${where} needs at least ${schema.minItems} item${schema.minItems === 1 ? "" : "s"}.` });
      }
      if (typeof schema.maxItems === "number" && value.length > schema.maxItems) {
        issues.push({ path, code: "too-many", message: `${where} can have at most ${schema.maxItems} items.` });
      }
      if (schema.uniqueItems === true) {
        const seen = new Set<string>();
        value.forEach((item, i) => {
          const key = JSON.stringify(item);
          if (seen.has(key)) issues.push({ path: joinPath(path, i), code: "duplicate", message: `${joinPath(path, i)} repeats an earlier item.` });
          seen.add(key);
        });
      }
      if (schema.items && typeof schema.items === "object") {
        value.forEach((item, i) => this.visit(schema.items as Schema, item, joinPath(path, i), issues));
      }
    }

    if (typeOf(value) === "object") {
      const obj = value as Record<string, unknown>;
      const props = (schema.properties ?? {}) as Record<string, Schema>;
      for (const key of (schema.required ?? []) as string[]) {
        if (!(key in obj)) issues.push({ path: joinPath(path, key), code: "missing", message: `${joinPath(path, key)} is required.` });
      }
      for (const [key, child] of Object.entries(obj)) {
        const childPath = joinPath(path, key);
        if (key in props) {
          this.visit(props[key] as Schema, child, childPath, issues);
        } else if (schema.additionalProperties === false) {
          issues.push({ path: childPath, code: "unknown-key", message: `${childPath} is not a setting HQ Booking knows.` });
        }
      }
    }
  }

  private visitOneOf(options: Schema[], value: unknown, path: string, issues: Issue[]): void {
    const results = options.map((option) => {
      const found: Issue[] = [];
      this.visit(option, value, path, found);
      return found;
    });
    if (results.some((r) => r.length === 0)) return;

    // Prefer the branch whose discriminator (a const property such as
    // source or type) matches, so the user sees errors for what they meant.
    if (typeOf(value) === "object") {
      const obj = value as Record<string, unknown>;
      for (let i = 0; i < options.length; i++) {
        const option = this.resolve(options[i] as Schema);
        const props = (option.properties ?? {}) as Record<string, Schema>;
        const disc = Object.entries(props).find(([, s]) => "const" in s);
        if (disc && obj[disc[0]] === disc[1].const) {
          issues.push(...(results[i] as Issue[]));
          return;
        }
      }
      const discKeys = new Set<string>();
      const allowed: unknown[] = [];
      for (const option of options) {
        const props = (this.resolve(option).properties ?? {}) as Record<string, Schema>;
        for (const [k, s] of Object.entries(props)) {
          if ("const" in s) {
            discKeys.add(k);
            allowed.push(s.const);
          }
        }
      }
      if (discKeys.size === 1) {
        const key = [...discKeys][0] as string;
        issues.push({ path: joinPath(path, key), code: "not-allowed", message: `${joinPath(path, key)} must be one of: ${allowed.join(", ")}.` });
        return;
      }
    }
    issues.push({ path, code: "no-match", message: `${path || "the file"} does not match any allowed shape.` });
  }
}
