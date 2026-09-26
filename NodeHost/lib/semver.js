'use strict';
// Semver subset sufficient for npm install resolution.
// Supports: exact ("1.2.3"), ^, ~, >=, <=, >, <, =, x-ranges ("1.2.x", "1.x",
// "*"), hyphen ranges ("1.2.3 - 2.3.4"), unions with "||", the "latest" tag,
// and whitespace-separated AND comparators. Pre-release tags are compared
// per semver rules but ranges with prereleases follow the simple common case.

function parseVersion(v) {
  if (typeof v !== 'string') return null;
  const m = v.trim().replace(/^v/, '').match(/^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/);
  if (!m) return null;
  return {
    major: +m[1], minor: +m[2], patch: +m[3],
    prerelease: m[4] ? m[4].split('.') : [],
  };
}

function compareIdentifiers(a, b) {
  const an = /^\d+$/.test(a), bn = /^\d+$/.test(b);
  if (an && bn) return (+a) - (+b);
  if (an) return -1; // numeric < alphanumeric
  if (bn) return 1;
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareVersions(a, b) {
  if (a.major !== b.major) return a.major - b.major;
  if (a.minor !== b.minor) return a.minor - b.minor;
  if (a.patch !== b.patch) return a.patch - b.patch;
  const ap = a.prerelease, bp = b.prerelease;
  if (!ap.length && !bp.length) return 0;
  if (!ap.length) return 1;  // release > prerelease
  if (!bp.length) return -1;
  const len = Math.min(ap.length, bp.length);
  for (let i = 0; i < len; i++) {
    const c = compareIdentifiers(ap[i], bp[i]);
    if (c !== 0) return c;
  }
  return ap.length - bp.length;
}

function isXRangePart(p) {
  return p === 'x' || p === 'X' || p === '*' || p === '' || p === undefined;
}

// Parse one comparator like ">=1.2.3", "^1.2", "~0.1.x", "1.2.3".
function parseComparator(raw) {
  const s = raw.trim();
  if (!s) return null;
  let m;
  if ((m = s.match(/^([<>]=?|=)?\s*v?(.*)$/))) {
    const op = m[1] || '';
    let rest = m[2];
    if (rest === '' || rest === '*' || /^[xX]$/.test(rest)) return { type: 'any' };
    if (rest.startsWith('^')) { rest = rest.slice(1); return caretRange(rest); }
    if (rest.startsWith('~')) { rest = rest.slice(1); return tildeRange(rest); }
    // partial / x-range
    const parts = rest.split('.');
    if (parts.some(isXRangePart)) {
      return xRange(op, parts);
    }
    const v = parseVersion(rest);
    if (!v) return null;
    switch (op) {
      case '': case '=': return { type: 'eq', v };
      case '>': return { type: 'gt', v };
      case '>=': return { type: 'gte', v };
      case '<': return { type: 'lt', v };
      case '<=': return { type: 'lte', v };
      default: return null;
    }
  }
  return null;
}

function padParts(parts) {
  const p = [...parts];
  while (p.length < 3) p.push('x');
  return p.slice(0, 3);
}

function lowerUpperFromPartial(parts) {
  // e.g. 1.2.x -> [1.2.0, 1.3.0); 1.x -> [1.0.0, 2.0.0)
  const p = padParts(parts);
  const lower = { major: +p[0] || 0, minor: +p[1] || 0, patch: +p[2] || 0, prerelease: [] };
  let upper;
  if (isXRangePart(p[0])) return { type: 'any' };
  if (isXRangePart(p[1])) upper = { major: lower.major + 1, minor: 0, patch: 0, prerelease: [] };
  else if (isXRangePart(p[2])) upper = { major: lower.major, minor: lower.minor + 1, patch: 0, prerelease: [] };
  else upper = null;
  return { lower, upper };
}

function xRange(op, parts) {
  const { lower, upper } = lowerUpperFromPartial(parts) || {};
  if (lower === undefined) return { type: 'any' };
  if (!upper) {
    const v = { major: +parts[0], minor: +parts[1], patch: +parts[2], prerelease: [] };
    switch (op) {
      case '': case '=': return { type: 'eq', v };
      case '>': return { type: 'gt', v };
      case '>=': return { type: 'gte', v };
      case '<': return { type: 'lt', v };
      case '<=': return { type: 'lte', v };
    }
  }
  switch (op) {
    case '': case '=':
      return { type: 'range', lower, upper, includeLower: true, includeUpper: false };
    case '>': return { type: 'gt', v: upperPrev(upper) }; // >1.2.x means >=1.3.0
    case '>=':
      return { type: 'gte', v: lower };
    case '<':
      return { type: 'lt', v: lower };
    case '<=':
      return { type: 'lt', v: upper };
    default: return null;
  }
}

function upperPrev(upper) {
  // For >1.2.x -> >=1.3.0. Represent as gte on upper.
  return upper;
}

function caretRange(rest) {
  const parts = rest.split('.');
  const p = padParts(parts);
  if (p.every(isXRangePart)) return { type: 'any' };
  const major = isXRangePart(p[0]) ? 0 : +p[0];
  const minor = isXRangePart(p[1]) ? 0 : +p[1];
  const patch = isXRangePart(p[2]) ? 0 : +p[2];
  const lower = { major, minor, patch, prerelease: [] };
  let upper;
  if (!isXRangePart(p[0]) && major > 0) upper = { major: major + 1, minor: 0, patch: 0, prerelease: [] };
  else if (!isXRangePart(p[1]) && major === 0 && minor > 0) upper = { major: 0, minor: minor + 1, patch: 0, prerelease: [] };
  else if (!isXRangePart(p[2]) && major === 0 && minor === 0) upper = { major: 0, minor: 0, patch: patch + 1, prerelease: [] };
  else if (isXRangePart(p[0])) return { type: 'any' };
  else if (isXRangePart(p[1])) upper = { major: major + 1, minor: 0, patch: 0, prerelease: [] };
  else upper = { major: major, minor: minor + 1, patch: 0, prerelease: [] };
  return { type: 'range', lower, upper, includeLower: true, includeUpper: false };
}

function tildeRange(rest) {
  const parts = rest.split('.');
  const p = padParts(parts);
  if (p.every(isXRangePart)) return { type: 'any' };
  const major = isXRangePart(p[0]) ? 0 : +p[0];
  const minor = isXRangePart(p[1]) ? 0 : +p[1];
  const patch = isXRangePart(p[2]) ? 0 : +p[2];
  const lower = { major, minor, patch, prerelease: [] };
  let upper;
  if (isXRangePart(p[0])) return { type: 'any' };
  if (isXRangePart(p[1])) upper = { major: major + 1, minor: 0, patch: 0, prerelease: [] };
  else upper = { major, minor: minor + 1, patch: 0, prerelease: [] };
  return { type: 'range', lower, upper, includeLower: true, includeUpper: false };
}

function testComparator(comp, v) {
  switch (comp.type) {
    case 'any': return true;
    case 'eq': return compareVersions(v, comp.v) === 0;
    case 'gt': return compareVersions(v, comp.v) > 0;
    case 'gte': return compareVersions(v, comp.v) >= 0;
    case 'lt': return compareVersions(v, comp.v) < 0;
    case 'lte': return compareVersions(v, comp.v) <= 0;
    case 'range': {
      const lo = compareVersions(v, comp.lower);
      const hi = compareVersions(v, comp.upper);
      return (comp.includeLower ? lo >= 0 : lo > 0) && (comp.includeUpper ? hi <= 0 : hi < 0);
    }
  }
  return false;
}

/** Parse a full range string into a list of comparator-set unions. */
function parseRange(range) {
  if (typeof range !== 'string') return null;
  const r = range.trim();
  if (r === '' || r === '*' || r === 'latest') return { unions: [[]], tag: r === 'latest' ? 'latest' : null };
  const unions = r.split('||').map((u) => {
    // hyphen range: "1.2.3 - 2.3.4"
    const hy = u.trim().match(/^(.+?)\s+-\s+(.+)$/);
    if (hy) {
      const lo = parseComparator('>=' + hy[1].trim());
      const hiParts = hy[2].trim().split('.');
      let hi;
      if (hiParts.some(isXRangePart)) {
        const { upper } = lowerUpperFromPartial(hiParts);
        hi = { type: 'lt', v: upper };
      } else {
        hi = parseComparator('<=' + hy[2].trim());
      }
      return [lo, hi].filter(Boolean);
    }
    return u.trim().split(/\s+/).map(parseComparator).filter(Boolean);
  });
  return { unions, tag: null };
}

function satisfies(versionStr, range) {
  const v = parseVersion(versionStr);
  if (!v) return false;
  const parsed = typeof range === 'string' ? parseRange(range) : range;
  if (!parsed) return false;
  if (parsed.tag === 'latest') return true; // caller handles tag
  return parsed.unions.some((comps) => comps.every((c) => testComparator(c, v)));
}

/**
 * Pick the best version from a list given a range and dist-tags.
 * @param {string[]} versions
 * @param {string} range
 * @param {Record<string,string>} [distTags] - e.g. {latest:"1.2.3"}
 * @returns {string|null}
 */
function maxSatisfying(versions, range, distTags) {
  const parsed = parseRange(range);
  if (!parsed) return null;
  if (parsed.tag === 'latest') {
    const latest = distTags && distTags.latest;
    return latest && versions.includes(latest) ? latest : null;
  }
  // Exact non-semver tag (e.g. "beta"): check dist-tags.
  if (distTags && distTags[range]) return distTags[range];
  const valid = versions
    .map((v) => ({ raw: v, parsed: parseVersion(v) }))
    .filter((x) => x.parsed)
    .filter((x) => parsed.unions.some((comps) => comps.every((c) => testComparator(c, x.parsed))))
    .sort((a, b) => compareVersions(a.parsed, b.parsed));
  if (!valid.length) return null;
  return valid[valid.length - 1].raw;
}

module.exports = { parseVersion, compareVersions, parseRange, satisfies, maxSatisfying };
