import { test } from 'node:test';
import assert from 'node:assert/strict';

import { union, intersect, measure, contains, toList } from '../src/rangeset.mjs';

test('并集把两组区间放在一起', () => {
  const merged = union([{ lo: 0, hi: 10 }], []);
  assert.deepEqual(toList(merged), [{ lo: 0, hi: 10 }]);
});

test('交集在没有公共部分时是空集', () => {
  const both = intersect([{ lo: 0, hi: 10 }], [{ lo: 20, hi: 30 }]);
  assert.deepEqual(toList(both), []);
});

test('测度、成员与展开', () => {
  assert.equal(measure([{ lo: 0, hi: 10 }]), 10);
  assert.equal(contains([{ lo: 0, hi: 10 }], 5), true);
  assert.deepEqual(toList([{ lo: 0, hi: 10 }]), [{ lo: 0, hi: 10 }]);
});
