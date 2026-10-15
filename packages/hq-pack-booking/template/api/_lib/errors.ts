// Errors the API turns into plain JSON responses. Anything else becomes a
// generic 500 with no stack trace or internal detail.

export class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details?: Record<string, unknown>;

  constructor(status: number, code: string, message: string, details?: Record<string, unknown>) {
    super(message);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

/**
 * A write lost a race: a primary key already exists, or the database refused
 * the transaction because a concurrent one changed the same rows (Aurora
 * DSQL SQLSTATE 40001 / OC000). Callers turn it into 409.
 */
export class ConflictError extends Error {
  constructor(message = "That was changed by someone else at the same moment.") {
    super(message);
    this.name = "ConflictError";
  }
}

/** A calendar, video, mail or DM provider refused or failed. */
export class ProviderError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, message: string, status = 502) {
    super(message);
    this.name = "ProviderError";
    this.code = code;
    this.status = status;
  }
}

export const badRequest = (code: string, message: string, details?: Record<string, unknown>) => new HttpError(400, code, message, details);
export const notFound = (message = "Not found.") => new HttpError(404, "not-found", message);
export const conflict = (code: string, message: string) => new HttpError(409, code, message);
