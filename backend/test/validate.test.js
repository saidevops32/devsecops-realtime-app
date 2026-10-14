const test = require('node:test');
const assert = require('node:assert');
const { validateTitle } = require('../src/validate');

test('accepts a normal title and trims it', () => {
  assert.strictEqual(validateTitle('  hello  '), 'hello');
});
test('rejects empty, non-string and too long titles', () => {
  assert.strictEqual(validateTitle(''), null);
  assert.strictEqual(validateTitle(123), null);
  assert.strictEqual(validateTitle('a'.repeat(101)), null);
});
