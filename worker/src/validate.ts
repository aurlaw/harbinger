import { InvalidRequest } from "./body";

// Small hand-rolled validators. Each throws InvalidRequest naming the field path.

export type Obj = Record<string, unknown>;

export function object(value: unknown, path: string): Obj {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new InvalidRequest(`${path} must be an object`);
  }
  return value as Obj;
}

export function array(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) throw new InvalidRequest(`${path} must be an array`);
  return value;
}

export function nonEmptyString(value: unknown, path: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new InvalidRequest(`${path} must be a non-empty string`);
  }
  return value;
}

export function integer(value: unknown, path: string, min: number, max: number): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
    throw new InvalidRequest(`${path} must be an integer between ${min} and ${max}`);
  }
  return value;
}

export function boolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") throw new InvalidRequest(`${path} must be a boolean`);
  return value;
}

export function oneOf<T extends string>(value: unknown, path: string, allowed: readonly T[]): T {
  if (typeof value !== "string" || !(allowed as readonly string[]).includes(value)) {
    throw new InvalidRequest(`${path} must be one of: ${allowed.join(", ")}`);
  }
  return value as T;
}

const LETTERBOXD_PREFIX = "https://boxd.it/";

export function letterboxdUri(value: unknown, path: string): string {
  if (typeof value !== "string" || !value.startsWith(LETTERBOXD_PREFIX) || value.length === LETTERBOXD_PREFIX.length) {
    throw new InvalidRequest(`${path} must be a Letterboxd URI starting with ${LETTERBOXD_PREFIX}`);
  }
  return value;
}

/** A real calendar date in YYYY-MM-DD form. */
export function isoDate(value: unknown, path: string): string {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}$/.test(value) ||
    new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) !== value
  ) {
    throw new InvalidRequest(`${path} must be a YYYY-MM-DD date`);
  }
  return value;
}

export function absent(obj: Obj, key: string, path: string): void {
  if (key in obj) throw new InvalidRequest(`${path}.${key} must be omitted`);
}

/** Validates each item and rejects a Letterboxd URI that appears twice. */
export function uniqueItems<T extends { letterboxd_uri: string }>(
  value: unknown,
  path: string,
  item: (obj: Obj, path: string) => T,
): T[] {
  const seen = new Set<string>();
  return array(value, path).map((raw, i) => {
    const itemPath = `${path}[${i}]`;
    const parsed = item(object(raw, itemPath), itemPath);
    if (seen.has(parsed.letterboxd_uri)) {
      throw new InvalidRequest(`${itemPath}.letterboxd_uri is a duplicate: ${parsed.letterboxd_uri}`);
    }
    seen.add(parsed.letterboxd_uri);
    return parsed;
  });
}
