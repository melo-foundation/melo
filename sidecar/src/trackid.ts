/**
 * A track id becomes a filename in the thumbnail cache, the lyrics cache and
 * imported local files, and plugin search results can supply ids: an id of
 * `../settings.v2` would make the lyrics cache overwrite the user's settings.
 * Allowlist: YouTube ids are [A-Za-z0-9_-]{11}, melo's imports `local-<uuid>`,
 * plugin sources prefix their own. Nothing that fits can traverse, be
 * absolute, or name a Windows device.
 */
const SAFE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)/i;

export function isSafeIdForPath(id: unknown): id is string {
  if (typeof id !== "string") return false;
  if (!SAFE.test(id)) return false;
  if (id.includes("..")) return false;          // ".." can't match SAFE's head, but be explicit
  if (RESERVED.test(id)) return false;
  return true;
}

/**
 * Throws rather than sanitising: a sanitised id would address a different
 * file than the caller thinks. Callers that can do without the cache catch.
 */
export function assertSafeIdForPath(id: unknown, what: string): string {
  if (!isSafeIdForPath(id))
    throw new Error(`melo: refusing to use ${JSON.stringify(String(id)).slice(0, 80)} as a ${what} filename`);
  return id;
}
