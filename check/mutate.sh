#!/usr/bin/env bash
# rangeset 的变异检查：对 src/rangeset.mjs 做单点位点替换，每个变异体各跑一次 node --test。
# **这是固定件，别改这个文件。**
#
# 用法：
#   bash check/mutate.sh                    跑全部位点，打印杀伤率
#   bash check/mutate.sh --timeout 0.5      单个变异体的 wall-clock 上限（秒），超时按被杀计
#   bash check/mutate.sh --threshold 0.95   自定义杀伤率阈值
#   bash check/mutate.sh -v                 逐位点打印 KILLED / SURVIVED
#   bash check/mutate.sh --verify-sites     位点自检：穷举差分确认每个位点都改变了公开 API 的可见行为
#
# stdout 固定输出：
#   SUMMARY sites=<位点数> killed=<被杀> survived=<存活> score=<杀伤率> elapsed=<秒> timeout=<秒>
#   杀伤率 X.XXX（40 个位点杀 N 个，阈值 0.95）
# 杀伤率 ≥ 阈值 exit 0，否则 exit 1；位点表或缺依赖 exit 2。
# 原仓库的 src/ 与 tests/ 只读：变异体一律写到临时目录里再跑。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

THRESHOLD=0.95
TIMEOUT=5
VERBOSE=0
VERIFY_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)   shift; TIMEOUT="${1:-5}" ;;
    --threshold) shift; THRESHOLD="${1:-0.95}" ;;
    -v|--verbose) VERBOSE=1 ;;
    --verify-sites) VERIFY_ONLY=1 ;;
    -h|--help)
      printf '用法: bash check/mutate.sh [--timeout <秒>] [--threshold <杀伤率>] [-v] [--verify-sites]\n'
      exit 0 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

[ -f src/rangeset.mjs ] || { printf '找不到 src/rangeset.mjs\n' >&2; exit 2; }
command -v node >/dev/null 2>&1 || { printf '找不到 node\n' >&2; exit 2; }

# ---------------------------------------------------------------------------
# 位点表：每行 id@@from@@to
#   from 必须在 src/rangeset.mjs 里**恰好出现一次**，否则视为位点表损坏（exit 2）。
#   表里的 40 个位点全部通过了 `--verify-sites` 的穷举差分（121 个集合的笛卡尔积 × 7 个公开
#   函数）：改动确实改变了公开 API 的可见行为，不存在「怎么改都杀不掉」的等价位点。
# ---------------------------------------------------------------------------
SITES='f01@@for (const piece of intervals) {@@for (const piece of intervals.slice(1)) {
f02@@if (lo >= hi) continue;@@if (lo > hi) continue;
f03@@kept.push({ lo: lo, hi: hi });@@kept.push({ lo: hi, hi: lo });
f04@@return compareLo(a.lo, b.lo);@@return compareLo(b.lo, a.lo);
f05@@if (last !== undefined && piece.lo <= last.hi) {@@if (last !== undefined && piece.lo < last.hi) {
f06@@if (piece.hi > last.hi) {@@if (piece.hi < last.hi) {
f07@@last.hi = piece.hi;@@last.hi = last.lo;
f08@@out.push({ lo: piece.lo, hi: piece.hi });@@out.push({ lo: piece.hi, hi: piece.lo });
f09@@return canonicalize(a.concat(b));@@return canonicalize(a.concat(a));
f10@@while (i < left.length && j < right.length) {@@while (i < left.length || j < right.length) {
f11@@const lo = left[i].lo > right[j].lo ? left[i].lo : right[j].lo;@@const lo = left[i].lo > right[j].lo ? right[j].lo : left[i].lo;
f12@@const hi = left[i].hi < right[j].hi ? left[i].hi : right[j].hi;@@const hi = left[i].hi < right[j].hi ? right[j].hi : left[i].hi;
f13@@if (lo < hi) {@@if (lo > hi) {
f14@@if (left[i].hi < right[j].hi) {@@if (left[i].hi > right[j].hi) {
f15@@j = j + 1;@@i = i + 1;
f16@@i = i + 1;@@j = j + 1;
f17@@export function difference(a, b) {@@export function difference(a, b) { if (b.length >= 0) { return canonicalize(a); }
f18@@for (const source of keep) {@@for (const source of cut) {
f19@@for (const hole of cut) {@@for (const hole of keep) {
f20@@const rest = [];@@const rest = pieces.concat([]);
f21@@rest.push({ lo: piece.lo, hi: hole.lo });@@rest.push({ lo: piece.lo, hi: hole.hi });
f22@@rest.push({ lo: hole.hi, hi: piece.hi });@@rest.push({ lo: hole.lo, hi: piece.hi });
f23@@out.push(piece);@@out.push({ lo: piece.hi, hi: piece.lo });
f24@@pieces = rest;@@pieces = pieces.concat(pieces);
f25@@export function complement(a) {@@export function complement(a) { if (a.length >= 0) { return a; }
f26@@let cursor = NEG_INF;@@let cursor = POS_INF;
f27@@if (piece.lo > cursor) {@@if (piece.lo > cursor && false) {
f28@@cursor = piece.hi;@@cursor = piece.lo;
f29@@if (cursor < POS_INF) {@@if (cursor > POS_INF) {
f30@@out.push({ lo: cursor, hi: piece.lo });@@out.push({ lo: piece.lo, hi: cursor });
f31@@out.push({ lo: cursor, hi: POS_INF });@@out.push({ lo: cursor, hi: NEG_INF });
f32@@if (piece.lo <= x && x < piece.hi) {@@if (piece.lo <= x && x <= piece.hi) {
f33@@return true;@@return false;
f34@@return false;@@return true;
f35@@let total = 0;@@let total = 1;
f36@@total = total + (piece.hi - piece.lo);@@total = total + (piece.lo - piece.hi);
f37@@return total;@@return total / 2;
f38@@for (const piece of canonicalize(set)) {@@for (const piece of canonicalize(set).slice(1)) {
f39@@return { lo: piece.lo, hi: piece.hi };@@return { lo: piece.hi, hi: piece.lo };
f40@@return canonicalize(set).map(function (piece) {@@return canonicalize(set).slice(1).map(function (piece) {'

# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

fail_env() { printf '%s\n' "$1" >&2; exit 2; }

# 用 $2 替换 src/rangeset.mjs 里唯一的 $1，写到 $3。绝不改原仓库文件。
mutate_file() {
  node -e '
    const fs = require("node:fs");
    const from = process.argv[1];
    const to = process.argv[2];
    const out = process.argv[3];
    const text = fs.readFileSync("src/rangeset.mjs", "utf8");
    const at = text.indexOf(from);
    if (at < 0) { console.error("SITE_FROM_NOT_FOUND\n" + from); process.exit(3); }
    if (text.indexOf(from, at + from.length) >= 0) { console.error("SITE_FROM_NOT_UNIQUE\n" + from); process.exit(4); }
    fs.writeFileSync(out, text.slice(0, at) + to + text.slice(at + from.length), "utf8");
  ' "$1" "$2" "$3"
}

ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !((a+0) >= (b+0))}'; }

# 临时目录一律建在 POSIX 路径下（Windows 上 mktemp 默认给带盘符的路径，那种路径删不干净）。
TMP="$(TMPDIR=/tmp mktemp -d 2>/dev/null)"
[ -n "$TMP" ] || fail_env '无法创建临时目录'
cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT
mkdir -p "$TMP/src" "$TMP/tests"
cp src/rangeset.mjs "$TMP/src/rangeset.mjs"
[ -d tests ] && cp -r tests/. "$TMP/tests/"
[ -f package.json ] && cp package.json "$TMP/package.json"

split_site() {  # $1 行 -> SITE_ID / SITE_FROM / SITE_TO
  SITE_ID="${1%%@@*}"
  local rest="${1#*@@}"
  SITE_FROM="${rest%%@@*}"
  SITE_TO="${rest#*@@}"
}

# ---------------------------------------------------------------------------
# --verify-sites：穷举差分（确定性，无随机）
# ---------------------------------------------------------------------------
run_verify() {
  local dir="$TMP/verify"
  mkdir -p "$dir"
  cp src/rangeset.mjs "$dir/orig.mjs"
  local -a args=("$dir/orig.mjs")
  local index=0 line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    split_site "$line"
    index=$((index + 1))
    local out="$dir/m$(printf '%03d' "$index").mjs"
    mutate_file "$SITE_FROM" "$SITE_TO" "$out" >/dev/null 2>&1 || fail_env "位点 $SITE_ID 替换失败（from 不唯一或找不到）"
    args+=("$SITE_ID=$out")
  done <<< "$SITES"

  cat > "$dir/harness.mjs" <<'HARNESS'
import { pathToFileURL } from 'node:url';

const [origPath, ...pairs] = process.argv.slice(2);
const ENDPOINTS = [-Infinity, 0, 1, 2, Infinity];
const POINTS = [-Infinity, -1, 0, 1, 2, 3, Infinity];

function allSets() {
  const pool = [];
  for (let i = 0; i < ENDPOINTS.length; i += 1) {
    for (let j = i; j < ENDPOINTS.length; j += 1) {
      pool.push({ lo: ENDPOINTS[i], hi: ENDPOINTS[j] });
    }
  }
  const out = [[]];
  for (let i = 0; i < pool.length; i += 1) {
    out.push([pool[i]]);
    for (let j = i + 1; j < pool.length; j += 1) {
      out.push([pool[i], pool[j]]);
    }
  }
  return out;
}

function enc(value) {
  if (Array.isArray(value)) return '[' + value.map(enc).join(',') + ']';
  if (value && typeof value === 'object') {
    return '{' + Object.keys(value).sort().map((k) => k + ':' + enc(value[k])).join(',') + '}';
  }
  if (typeof value === 'number') {
    if (Object.is(value, -Infinity)) return '-I';
    if (value === Infinity) return 'I';
    return String(value);
  }
  return String(value);
}

function capture(fn) {
  try {
    return enc(fn());
  } catch (err) {
    return 'THROW:' + (err && err.name ? err.name : 'Err');
  }
}

const SETS = allSets();
const PAIRS = [];
for (const a of SETS) for (const b of SETS) PAIRS.push([a, b]);

function observe(mod) {
  const parts = [];
  for (const [a, b] of PAIRS) {
    parts.push(capture(() => mod.union(a, b)));
    parts.push(capture(() => mod.intersect(a, b)));
    parts.push(capture(() => mod.difference(a, b)));
  }
  for (const a of SETS) {
    parts.push(capture(() => mod.complement(a)));
    parts.push(capture(() => mod.measure(a)));
    parts.push(capture(() => mod.toList(a)));
    for (const x of POINTS) parts.push(capture(() => mod.contains(a, x)));
  }
  return parts.join(';');
}

const orig = await import(pathToFileURL(origPath).href);
const base = observe(orig);
let same = 0;
for (const pair of pairs) {
  const cut = pair.indexOf('=');
  const id = pair.slice(0, cut);
  const file = pair.slice(cut + 1);
  let mod = null;
  try {
    mod = await import(pathToFileURL(file).href);
  } catch (err) {
    console.log('SITE ' + id + ' BROKEN ' + (err && err.message ? err.message : err));
    same += 1;
    continue;
  }
  if (observe(mod) === base) {
    console.log('SITE ' + id + ' SAME');
    same += 1;
  } else {
    console.log('SITE ' + id + ' CHANGED');
  }
}
console.log('VERIFY sites=' + pairs.length + ' changed=' + (pairs.length - same) + ' same=' + same);
process.exit(same === 0 ? 0 : 1);
HARNESS

  printf '穷举差分：121 个集合的两两组合 × 3 个二元运算 + 一元运算，端点含 ±Infinity\n'
  node "$dir/harness.mjs" "${args[@]}"
}

if [ "$VERIFY_ONLY" = "1" ]; then
  run_verify
  exit $?
fi

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------
sites=0
killed=0
survived=0
survivors=""
t0="$(date +%s%3N)"

while IFS= read -r line; do
  [ -z "$line" ] && continue
  split_site "$line"
  sites=$((sites + 1))
  if ! mutate_file "$SITE_FROM" "$SITE_TO" "$TMP/src/rangeset.mjs" >/dev/null 2>&1; then
    fail_env "位点 $SITE_ID 替换失败（from 不唯一或找不到）"
  fi
  ( cd "$TMP" && timeout "$TIMEOUT" node --test ) >/dev/null 2>&1
  status=$?
  if [ "$status" -ne 0 ]; then
    killed=$((killed + 1))
    [ "$VERBOSE" = "1" ] && printf 'KILLED %s\n' "$SITE_ID"
  else
    survived=$((survived + 1))
    survivors="$survivors $SITE_ID"
    [ "$VERBOSE" = "1" ] && printf 'SURVIVED %s\n' "$SITE_ID"
  fi
done <<< "$SITES"

t1="$(date +%s%3N)"
elapsed="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", (b - a) / 1000.0}')"
score="$(awk -v k="$killed" -v n="$sites" 'BEGIN{printf "%.3f", (n > 0 ? k / n : 0)}')"

printf 'SUMMARY sites=%d killed=%d survived=%d score=%s elapsed=%s timeout=%s\n' \
  "$sites" "$killed" "$survived" "$score" "$elapsed" "$TIMEOUT"
if [ "$survived" -gt 0 ]; then
  printf '存活位点:%s\n' "$survivors"
fi

printf '杀伤率 %s（%d 个位点杀 %d 个，阈值 %s）\n' "$score" "$sites" "$killed" "$THRESHOLD"

if ge "$score" "$THRESHOLD"; then
  exit 0
fi
exit 1
