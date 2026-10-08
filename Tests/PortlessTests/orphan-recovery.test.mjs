import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

function fixture(entry, mode = 'orphan') {
  const args = entry === 'setup' ? ['/source', '/Users/fixture', 'fixture', '501', '20']
    : ['/Users/fixture', 'fixture', '501', '-'];
  const result = spawnSync(process.execPath, ['--import', './Tests/PortlessTests/fixtures/orphan-installation.mjs',
    `Resources/Portless/${entry}.mjs`, ...args], {encoding: 'utf8', timeout: 10000,
    env: {...process.env, LEFTOPEN_FIXTURE_MODE: mode}});
  const record = JSON.parse(result.stdout.split('\n').find(line => line.startsWith('FIXTURE:')).slice(8));
  return {...result, ...record};
}

test('real setup entry recovers missing PID/certificate/runtime with an owned live daemon', () => {
  const result = fixture('setup');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /trustRequired/);
  const bootout = result.trace.findIndex(([command, args]) => command === '/bin/launchctl' && args[0] === 'bootout');
  const install = result.trace.findIndex(([, args]) => args[1] === 'service' && args[2] === 'install');
  assert.ok(bootout >= 0 && install > bootout);
  assert.equal(result.trace.some(([, args]) => args.includes('kill')), false);
});

test('real uninstall entry removes orphaned service while leaving every keychain untouched', () => {
  const result = fixture('uninstall');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /removed:certificateUnresolved/);
  assert.ok(result.trace.some(([command, args]) => command === '/bin/launchctl' && args[0] === 'bootout'));
  assert.ok(result.deleted.includes('/Library/LaunchDaemons/app.leftopen.portless.proxy.plist'));
  assert.equal(result.trace.some(([command]) => command === '/usr/bin/security'), false);
});

for (const mode of ['fresh', 'dormant']) {
  test(`setup still installs from ${mode} state without stopping an unrelated service`, () => {
    const result = fixture('setup', mode);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /trustRequired/);
    assert.equal(result.trace.some(([, args]) => args[0] === 'bootout'), false);
  });
}

for (const entry of ['setup', 'uninstall']) {
  for (const mode of ['delayed-stop', 'error-but-stopped']) {
    test(`${entry} accepts confirmed absence after ${mode}`, () => {
      const result = fixture(entry, mode);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.trace.filter(([, args]) => args[0] === 'bootout').length, 1);
    });
  }
  for (const [mode, code] of [['pending-stop', 'serviceStopPending'], ['verify-fails', 'stopVerificationFailed']]) {
    test(`${entry} reports ${code} without assuming the service stopped`, () => {
      const result = fixture(entry, mode);
      assert.equal(result.status, 1);
      assert.match(result.stderr, new RegExp(code));
      assert.match(result.stderr, /LEFTOPEN_DIAGNOSTIC:.*launchd.bootout/);
      assert.match(result.stderr, /LEFTOPEN_DIAGNOSTIC:.*launchd.verifyStopped/);
      assert.deepEqual(result.deleted, []);
      assert.equal(result.trace.filter(([, args]) => args[0] === 'bootout').length, 1);
    });
  }
  for (const mode of ['wrong-process', 'other-user', 'unsafe-plist', 'loaded-mismatch', 'missing-plist', 'pid-changed']) {
    test(`${entry} refuses ${mode} without stopping any service or deleting files`, () => {
      const result = fixture(entry, mode);
      assert.equal(result.status, 1);
      const code = mode === 'other-user' ? 'differentOwner' : mode === 'pid-changed' ? 'serviceChanged'
        : entry === 'uninstall' && mode === 'unsafe-plist' ? 'unsafePath' : 'unsafeService';
      assert.equal(result.stderr, code + '\n');
      assert.equal(result.trace.some(([, args]) => args[0] === 'bootout'), false);
      assert.deepEqual(result.deleted, []);
    });
  }
  test(`${entry} aborts when verified daemon refuses to stop`, () => {
    const result = fixture(entry, 'stop-fails');
    assert.equal(result.status, 1);
    assert.match(result.stderr, /serviceStopFailed/);
    assert.match(result.stderr, /"exitCode":5/);
    assert.deepEqual(result.deleted, []);
  });
}

test('setup refuses a different HTTPS listener even when LeftOpen launchd metadata exists', () => {
  const result = fixture('setup', 'foreign-listener');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /portBusy/);
  assert.equal(result.trace.some(([, args]) => args[0] === 'bootout'), false);
});
