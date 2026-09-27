// check/probe.mjs —— 固定件：hygiene / discriminate / scale 三组的进程内检查。
// **别改这个文件。**
//
// 用法：node check/probe.mjs
//
// 输出（逐行）：
//   RESULT <组>/<名> OK
//   RESULT <组>/<名> FAIL <细节>
// 组/名共 6 个：
//   hygiene/no_source_read     用例不读源码与字节码（readFile / createRequire / __filename /
//                              Buffer.from / import() 带查询串 / node:fs / require()）
//   hygiene/no_private_symbol  用例不 import `_` 前缀私有符号，也不 import `_` 前缀路径段
//   hygiene/no_time_random     用例不用定时器、Math.random、Date.now 等让用例「碰巧」通过
//   discriminate/pairs         4 对语义近邻，各自的两个近似实现都要被用例杀掉
//   discriminate/public_api    每对语义近邻都存在一个「只走公开导出、返回不同值」的区分性输入
//   scale/test_count           仓库根目录裸跑 node --test，用例数 ≥ 40
//
// 只依赖 node: 内置模块。用例文件本身不会被 import，只会被静态扫描。

import { readFileSync, readdirSync, mkdtempSync, mkdirSync, writeFileSync, cpSync, rmSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, relative } from 'node:path';
import { tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(HERE);
const SRC = join(ROOT, 'src', 'rangeset.mjs');
const MIN_TESTS = 40;
const VARIANT_TIMEOUT_MS = 30000;

const results = [];
function put(key, ok, detail) {
  results.push({ key, ok, detail: detail || '' });
}

// ---------------------------------------------------------------------------
// 收集用例文件
// ---------------------------------------------------------------------------
function collect(dir) {
  const out = [];
  const walk = (d) => {
    let entries;
    try {
      entries = readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name === 'node_modules') continue;
      const full = join(d, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (/\.(mjs|cjs|js)$/.test(entry.name)) {
        out.push(full);
      }
    }
  };
  walk(dir);
  return out.sort();
}

const testFiles = collect(join(ROOT, 'tests'));
const testSources = testFiles.map((file) => ({
  file: relative(ROOT, file).split('\\').join('/'),
  text: readFileSync(file, 'utf8'),
}));

function scan(patterns) {
  const hits = [];
  for (const { file, text } of testSources) {
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i += 1) {
      for (const [re, label] of patterns) {
        if (re.test(lines[i])) {
          hits.push(`${file}:${i + 1} ${label}`);
          break;
        }
      }
    }
  }
  return hits;
}

function summarize(hits) {
  if (hits.length === 0) return '';
  const shown = hits.slice(0, 3).join('、');
  return hits.length > 3 ? `${shown}、…（共 ${hits.length} 处）` : shown;
}

// ---------------------------------------------------------------------------
// hygiene
// ---------------------------------------------------------------------------
const SOURCE_READ_PATTERNS = [
  [/\breadFileSync\s*\(/, 'readFileSync('],
  [/\breadFile\s*\(/, 'readFile('],
  [/\bcreateReadStream\b/, 'createReadStream'],
  [/\bcreateRequire\b/, 'createRequire'],
  [/__filename/, '__filename'],
  [/__dirname/, '__dirname'],
  [/\bBuffer\s*\.\s*from/, 'Buffer.from'],
  [/\brequire\s*\(/, 'require('],
  [/\bimport\s*\(\s*[^)]*\?/, 'import() 带查询串'],
  [/\bnode:fs\b/, 'node:fs'],
  [/\bnode:module\b/, 'node:module'],
  [/\bprocess\s*\.\s*binding/, 'process.binding'],
  [/\bgetBuiltinModule\b/, 'getBuiltinModule'],
  [/\bchild_process\b/, 'child_process'],
];

const TIME_RANDOM_PATTERNS = [
  [/\bsetTimeout\b/, 'setTimeout'],
  [/\bsetInterval\b/, 'setInterval'],
  [/\bsetImmediate\b/, 'setImmediate'],
  [/\bqueueMicrotask\b/, 'queueMicrotask'],
  [/\bMath\s*\.\s*random/, 'Math.random'],
  [/\bDate\s*\.\s*now/, 'Date.now'],
  [/\bnew\s+Date\b/, 'new Date'],
  [/\bperformance\s*\.\s*now/, 'performance.now'],
  [/\bhrtime\b/, 'hrtime'],
  [/\brandomUUID\b/, 'randomUUID'],
];

function privateSymbolHits() {
  const hits = [];
  const importRe = /import\s*(\{([^}]*)\}|\*\s+as\s+([\w$]+)|([\w$]+))?\s*from\s*['"]([^'"]+)['"]/g;
  const dynamicRe = /import\s*\(\s*['"]([^'"]+)['"]\s*\)/g;
  for (const { file, text } of testSources) {
    let m;
    importRe.lastIndex = 0;
    while ((m = importRe.exec(text)) !== null) {
      const names = m[2];
      const star = m[3];
      const dflt = m[4];
      const path = m[5];
      if (star && star.startsWith('_')) hits.push(`${file} import * as ${star}`);
      if (dflt && dflt.startsWith('_')) hits.push(`${file} import ${dflt}`);
      if (names) {
        for (const raw of names.split(',')) {
          const parts = raw.trim().split(/\s+as\s+/);
          for (const part of parts) {
            const name = part.trim();
            if (name && name.startsWith('_')) hits.push(`${file} import { ${name} } from '${path}'`);
          }
        }
      }
      for (const seg of path.split('/')) {
        if (seg.startsWith('_')) hits.push(`${file} import '${path}'`);
      }
    }
    dynamicRe.lastIndex = 0;
    while ((m = dynamicRe.exec(text)) !== null) {
      for (const seg of m[1].split('/')) {
        if (seg.startsWith('_')) hits.push(`${file} import('${m[1]}')`);
      }
    }
  }
  return hits;
}

put('hygiene/no_source_read',
  scan(SOURCE_READ_PATTERNS).length === 0 ? true : false,
  summarize(scan(SOURCE_READ_PATTERNS)));

const privateHits = privateSymbolHits();
put('hygiene/no_private_symbol', privateHits.length === 0, summarize(privateHits));

const timeHits = scan(TIME_RANDOM_PATTERNS);
put('hygiene/no_time_random', timeHits.length === 0, summarize(timeHits));

// ---------------------------------------------------------------------------
// 变异体：4 对语义近邻，每对一个 A 一个 B
// ---------------------------------------------------------------------------
const NEIGHBOURS = [
  {
    name: 'union↔intersect 混用',
    a: { from: 'return canonicalize(a.concat(b));', to: 'return intersect(a, b);' },
    b: { from: 'export function intersect(a, b) {', to: 'export function intersect(a, b) { return canonicalize(a.concat(b));' },
  },
  {
    name: '相邻相接的合并开关（<= 与 <）',
    a: { from: 'if (last !== undefined && piece.lo <= last.hi) {', to: 'if (last !== undefined && piece.lo < last.hi) {' },
    b: { from: 'if (last !== undefined && piece.lo <= last.hi) {', to: 'if (last !== undefined && piece.lo <= last.hi + 1) {' },
  },
  {
    name: '合并时延长右端点',
    a: { from: 'if (piece.hi > last.hi) {', to: 'if (piece.hi < last.hi) {' },
    b: { from: 'last.hi = piece.hi;', to: 'last.hi = last.lo;' },
  },
  {
    name: '空集与零长区间',
    a: { from: 'if (lo >= hi) continue;', to: 'if (lo > hi) continue;' },
    b: { from: 'const kept = [];', to: 'const kept = [{ lo: 0, hi: 0 }];' },
  },
];

const original = readFileSync(SRC, 'utf8');

function makeVariant(spec, outPath) {
  const at = original.indexOf(spec.from);
  if (at < 0) return 'from 在 src/rangeset.mjs 里找不到：' + spec.from;
  if (original.indexOf(spec.from, at + spec.from.length) >= 0) return 'from 在 src/rangeset.mjs 里不唯一：' + spec.from;
  writeFileSync(outPath, original.slice(0, at) + spec.to + original.slice(at + spec.from.length), 'utf8');
  return null;
}

const scratch = mkdtempSync(join(tmpdir(), 'gsb95-probe-'));
mkdirSync(join(scratch, 'src'), { recursive: true });
cpSync(SRC, join(scratch, 'src', 'rangeset.mjs'));
cpSync(join(ROOT, 'tests'), join(scratch, 'tests'), { recursive: true });
if (existsSync(join(ROOT, 'package.json'))) cpSync(join(ROOT, 'package.json'), join(scratch, 'package.json'));

function suiteFails(cwd) {
  const run = spawnSync('node', ['--test'], {
    cwd,
    timeout: VARIANT_TIMEOUT_MS,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (run.error) return true; // 超时/起不来也按「被杀」计
  return run.status !== 0;
}

const killed = new Map();
for (const pair of NEIGHBOURS) {
  for (const side of ['a', 'b']) {
    const key = `${pair.name}/${side}`;
    const problem = makeVariant(pair[side], join(scratch, 'src', 'rangeset.mjs'));
    killed.set(key, problem === null ? suiteFails(scratch) : false);
    if (problem !== null) killed.set(key, false);
  }
}

const pairProblems = [];
for (const pair of NEIGHBOURS) {
  const ka = killed.get(`${pair.name}/a`);
  const kb = killed.get(`${pair.name}/b`);
  if (!(ka && kb)) {
    pairProblems.push(`${pair.name}（${ka ? '' : 'A 未被杀 '}${kb ? '' : 'B 未被杀'}）`.replace(/\s+$/, ''));
  }
}
put('discriminate/pairs', pairProblems.length === 0,
  pairProblems.length === 0 ? '' : summarize(pairProblems));

// ---------------------------------------------------------------------------
// 区分性输入：只走公开导出，两个近似实现必须返回**不同的值**（不是靠抛异常）
// ---------------------------------------------------------------------------
function show(value) {
  if (Array.isArray(value)) return '[' + value.map(show).join(',') + ']';
  if (value && typeof value === 'object') {
    return '{' + Object.keys(value).sort().map((k) => k + ':' + show(value[k])).join(',') + '}';
  }
  if (typeof value === 'number') {
    if (Object.is(value, -Infinity)) return '-Infinity';
    if (value === Infinity) return 'Infinity';
    return String(value);
  }
  return String(value);
}

function attempt(fn) {
  try {
    return { ok: true, value: show(fn()) };
  } catch {
    return { ok: false, value: 'throw' };
  }
}

function corpus() {
  const endpoints = [-Infinity, -1, 0, 1, 2, 3, 5, Infinity];
  const pool = [];
  for (let i = 0; i < endpoints.length; i += 1) {
    for (let j = i; j < endpoints.length; j += 1) {
      pool.push({ lo: endpoints[i], hi: endpoints[j] });
    }
  }
  const sets = [[]];
  for (let i = 0; i < pool.length; i += 1) {
    sets.push([pool[i]]);
    for (let j = i + 1; j < pool.length; j += 1) sets.push([pool[i], pool[j]]);
  }
  return { sets, points: endpoints.concat([1.5, 4]) };
}

const CORPUS = corpus();

async function findDiscriminator(modA, modB) {
  const ops = ['union', 'intersect', 'difference'];
  for (const a of CORPUS.sets) {
    for (const b of CORPUS.sets) {
      for (const op of ops) {
        const ra = attempt(() => modA[op](a, b));
        const rb = attempt(() => modB[op](a, b));
        if (ra.ok && rb.ok && ra.value !== rb.value) {
          return `${op}(${show(a)}, ${show(b)}) ⇒ ${ra.value} ≠ ${rb.value}`;
        }
      }
    }
  }
  for (const a of CORPUS.sets) {
    for (const op of ['complement', 'measure', 'toList']) {
      const ra = attempt(() => modA[op](a));
      const rb = attempt(() => modB[op](a));
      if (ra.ok && rb.ok && ra.value !== rb.value) {
        return `${op}(${show(a)}) ⇒ ${ra.value} ≠ ${rb.value}`;
      }
    }
    for (const x of CORPUS.points) {
      const ra = attempt(() => modA.contains(a, x));
      const rb = attempt(() => modB.contains(a, x));
      if (ra.ok && rb.ok && ra.value !== rb.value) {
        return `contains(${show(a)}, ${show(x)}) ⇒ ${ra.value} ≠ ${rb.value}`;
      }
    }
  }
  return null;
}

const apiProblems = [];
for (const pair of NEIGHBOURS) {
  const fileA = join(scratch, `A-${NEIGHBOURS.indexOf(pair)}.mjs`);
  const fileB = join(scratch, `B-${NEIGHBOURS.indexOf(pair)}.mjs`);
  const pa = makeVariant(pair.a, fileA);
  const pb = makeVariant(pair.b, fileB);
  if (pa || pb) {
    apiProblems.push(`${pair.name}（${pa || pb}）`);
    continue;
  }
  const modA = await import(pathToFileURL(fileA).href);
  const modB = await import(pathToFileURL(fileB).href);
  const found = await findDiscriminator(modA, modB);
  if (found === null) apiProblems.push(`${pair.name}（找不到只走公开导出的区分性输入）`);
}
put('discriminate/public_api', apiProblems.length === 0,
  apiProblems.length === 0 ? '' : summarize(apiProblems));

// ---------------------------------------------------------------------------
// scale：仓库根裸跑 node --test 的用例数
// ---------------------------------------------------------------------------
function countTests() {
  const run = spawnSync('node', ['--test'], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 120000,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const out = `${run.stdout || ''}\n${run.stderr || ''}`;
  const m = out.match(/^# tests (\d+)/m);
  return m ? Number(m[1]) : null;
}

const total = countTests();
put('scale/test_count', total !== null && total >= MIN_TESTS,
  total === null
    ? '没能从 node --test 的输出里读出用例数'
    : `用例数 ${total}（要求 ≥ ${MIN_TESTS}）`);

// ---------------------------------------------------------------------------
// 输出
// ---------------------------------------------------------------------------
for (const item of results) {
  const detail = item.key === 'scale/test_count' ? ` ${item.detail}` : item.ok ? '' : ` ${item.detail}`;
  console.log(`RESULT ${item.key} ${item.ok ? 'OK' : 'FAIL'}${detail}`);
}

try {
  rmSync(scratch, { recursive: true, force: true });
} catch {
  /* 临时目录清不掉不影响判定 */
}
