'use strict';
// Minimal shell-words parser for npm scripts.
// Supports: single/double quotes, backslash escapes, && || ; operators,
// VAR=value env assignments at segment start, basic redirection stripping is
// NOT supported (no fs redirection in the mobile runtime).
//
// parse(script) -> [{ env: {K:V}, argv: [...], op: null|'&&'|'||'|';' }]
// where `op` is the operator FOLLOWING this segment.

const OPERATORS = new Set(['&&', '||', ';']);

function tokenize(input) {
  const tokens = [];
  let i = 0;
  const n = input.length;
  while (i < n) {
    const c = input[i];
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') { i++; continue; }
    if (c === '#') { // comment to end of line
      while (i < n && input[i] !== '\n') i++;
      continue;
    }
    if (input.startsWith('&&', i)) { tokens.push({ op: '&&' }); i += 2; continue; }
    if (input.startsWith('||', i)) { tokens.push({ op: '||' }); i += 2; continue; }
    if (c === ';') { tokens.push({ op: ';' }); i++; continue; }
    // word
    let word = '';
    while (i < n) {
      const ch = input[i];
      if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === ';') break;
      if (input.startsWith('&&', i) || input.startsWith('||', i)) break;
      if (ch === '\\') {
        if (i + 1 < n) { word += input[i + 1]; i += 2; continue; }
        i++; continue;
      }
      if (ch === "'") {
        i++;
        while (i < n && input[i] !== "'") word += input[i++];
        i++; // closing quote (or end of input)
        continue;
      }
      if (ch === '"') {
        i++;
        while (i < n && input[i] !== '"') {
          if (input[i] === '\\' && i + 1 < n && '"\\$`'.includes(input[i + 1])) {
            word += input[i + 1]; i += 2; continue;
          }
          word += input[i++];
        }
        i++;
        continue;
      }
      word += ch;
      i++;
    }
    tokens.push({ word });
  }
  return tokens;
}

const ENV_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

function parse(script) {
  if (typeof script !== 'string') return [];
  const tokens = tokenize(script);
  const segments = [];
  let cur = { env: {}, argv: [], op: null };
  let seenCmd = false;
  for (const t of tokens) {
    if (t.op) {
      cur.op = t.op;
      if (cur.argv.length || Object.keys(cur.env).length) segments.push(cur);
      cur = { env: {}, argv: [], op: null };
      seenCmd = false;
      continue;
    }
    if (!seenCmd && ENV_RE.test(t.word)) {
      const eq = t.word.indexOf('=');
      cur.env[t.word.slice(0, eq)] = t.word.slice(eq + 1);
      continue;
    }
    seenCmd = true;
    cur.argv.push(t.word);
  }
  if (cur.argv.length || Object.keys(cur.env).length) segments.push(cur);
  return segments;
}

module.exports = { parse, tokenize };
