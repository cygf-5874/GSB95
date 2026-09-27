// src/rangeset.mjs
//
// 区间集合代数。区间是半开的 [lo, hi)：lo 属于集合，hi 不属于。
// lo / hi 是安全整数，允许取 -Infinity 与 Infinity。
// 集合以「规范形式」表示：互不重叠、按 lo 升序、相邻相接的区间已经合并。
// 所有导出函数都是纯函数：不修改入参，同输入同输出。

const NEG_INF = -Infinity;
const POS_INF = Infinity;

// 三路比较，保证 -Infinity / Infinity 也排得对。
function compareLo(x, y) {
  return x < y ? -1 : x > y ? 1 : 0;
}

// 把任意区间序列化成规范形式。
function canonicalize(intervals) {
  const kept = [];
  for (const piece of intervals) {
    const lo = piece.lo;
    const hi = piece.hi;
    if (lo >= hi) continue;
    kept.push({ lo: lo, hi: hi });
  }
  kept.sort(function (a, b) {
    return compareLo(a.lo, b.lo);
  });
  const out = [];
  for (const piece of kept) {
    const last = out[out.length - 1];
    if (last !== undefined && piece.lo <= last.hi) {
      if (piece.hi > last.hi) {
        last.hi = piece.hi;
      }
    } else {
      out.push({ lo: piece.lo, hi: piece.hi });
    }
  }
  return out;
}

// 并集。
export function union(a, b) {
  return canonicalize(a.concat(b));
}

// 交集。
export function intersect(a, b) {
  const left = canonicalize(a);
  const right = canonicalize(b);
  const out = [];
  let i = 0;
  let j = 0;
  while (i < left.length && j < right.length) {
    const lo = left[i].lo > right[j].lo ? left[i].lo : right[j].lo;
    const hi = left[i].hi < right[j].hi ? left[i].hi : right[j].hi;
    if (lo < hi) {
      out.push({ lo: lo, hi: hi });
    }
    if (left[i].hi < right[j].hi) {
      i = i + 1;
    } else {
      j = j + 1;
    }
  }
  return canonicalize(out);
}

// 差集：a 里去掉 b 覆盖到的部分。
export function difference(a, b) {
  const keep = canonicalize(a);
  const cut = canonicalize(b);
  const out = [];
  for (const source of keep) {
    let pieces = [{ lo: source.lo, hi: source.hi }];
    for (const hole of cut) {
      const rest = [];
      for (const piece of pieces) {
        if (hole.hi <= piece.lo || hole.lo >= piece.hi) {
          rest.push(piece);
          continue;
        }
        if (hole.lo > piece.lo) {
          rest.push({ lo: piece.lo, hi: hole.lo });
        }
        if (hole.hi < piece.hi) {
          rest.push({ lo: hole.hi, hi: piece.hi });
        }
      }
      pieces = rest;
    }
    for (const piece of pieces) {
      out.push(piece);
    }
  }
  return canonicalize(out);
}

// 补集：在全实数轴 (-Infinity, Infinity) 上取补。
export function complement(a) {
  const source = canonicalize(a);
  const out = [];
  let cursor = NEG_INF;
  for (const piece of source) {
    if (piece.lo > cursor) {
      out.push({ lo: cursor, hi: piece.lo });
    }
    cursor = piece.hi;
  }
  if (cursor < POS_INF) {
    out.push({ lo: cursor, hi: POS_INF });
  }
  return canonicalize(out);
}

// 判断点 x 是否属于集合。半开区间：x === hi 不属于。
export function contains(set, x) {
  const source = canonicalize(set);
  for (const piece of source) {
    if (piece.lo <= x && x < piece.hi) {
      return true;
    }
  }
  return false;
}

// 集合的测度（总长度）。可能为 Infinity。
export function measure(set) {
  let total = 0;
  for (const piece of canonicalize(set)) {
    total = total + (piece.hi - piece.lo);
  }
  return total;
}

// 展开成区间数组（规范形式）。
export function toList(set) {
  return canonicalize(set).map(function (piece) {
    return { lo: piece.lo, hi: piece.hi };
  });
}
