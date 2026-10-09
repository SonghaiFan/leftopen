import test from 'node:test';
import assert from 'node:assert/strict';
import { selectProxyPort } from '../../Resources/Portless/proxy-config.mjs';

test('automatic selection retains available saved port and skips consecutive conflicts', async () => {
  assert.equal(await selectProxyPort(9443, async () => false, () => false), 9443);
  assert.equal(await selectProxyPort(443, async p => [443,8443,8444].includes(p), () => false), 8445);
});
test('owned preferred listener is retained but alternatives are never adopted', async () => {
  assert.equal(await selectProxyPort(443, async () => true, () => true), 443);
  await assert.rejects(selectProxyPort(443, async () => true, () => false), /portBusy/);
});
test('inspection failure is not treated as an available port', async () => {
  await assert.rejects(selectProxyPort(443, async () => { throw new Error('portCheckFailed'); }, () => false), /portCheckFailed/);
  await assert.rejects(selectProxyPort(443, async () => true, () => { throw new Error('unsafeService'); }), /unsafeService/);
});
