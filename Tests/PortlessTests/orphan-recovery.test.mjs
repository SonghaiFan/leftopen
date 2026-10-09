import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

function fixture(entry, mode = 'orphan', port, oldPort = '443', foreignPort = '0', automatic = false) {
  const args = entry === 'setup' ? ['/source', '/Users/fixture', 'fixture', '501', '20']
    : ['/Users/fixture', 'fixture', '501', '-'];
  if (entry === 'setup' && port !== undefined) args.push(port);
  if (automatic) args.push('auto');
  const result = spawnSync(process.execPath, ['--import', './Tests/PortlessTests/fixtures/orphan-installation.mjs',
    `Resources/Portless/${entry}.mjs`, ...args], {encoding: 'utf8', timeout: 10000,
    env: {...process.env, LEFTOPEN_FIXTURE_MODE: mode, LEFTOPEN_FIXTURE_PORT: oldPort,
      LEFTOPEN_FIXTURE_FOREIGN_PORT: foreignPort}});
  const record = JSON.parse(result.stdout.split('\n').find(line => line.startsWith('FIXTURE:')).slice(8));
  return {...result, ...record};
}

test('custom HTTPS port installs while an unrelated proxy keeps 443', () => {
  const result = fixture('setup', 'fresh', '8443', '443', '443');
  assert.equal(result.status, 0, result.stderr);
  assert.ok(!result.trace.some(([, args]) => args[0] === 'bootout'));
  const install = result.trace.find(([, args]) => args[1] === 'service' && args[2] === 'install');
  assert.equal(install[1].at(-1), '8443');
});

test('automatic setup avoids foreign 443 without stopping it and reports the selected port', () => {
  const result = fixture('setup', 'fresh', '443', '443', '443', true);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /port:8443/);
  assert.ok(!result.trace.some(([, args]) => args[0] === 'bootout'));
  assert.equal(result.trace.find(([, args]) => args[1] === 'service' && args[2] === 'install')[1].at(-1), '8443');
});

test('automatic repair keeps the verified owned port', () => {
  const result = fixture('setup', 'orphan', '443', '8443', '0', true);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /port:8443/);
});

test('port migration verifies and stops only the owned old listener', () => {
  const result = fixture('setup', 'orphan', '8443');
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.trace.some(([command, args]) => command === '/usr/sbin/lsof' && args.includes('-iTCP:443')));
  assert.ok(result.trace.some(([, args]) => args[0] === 'bootout'));
  assert.equal(result.trace.find(([, args]) => args[1] === 'service' && args[2] === 'install')[1].at(-1), '8443');
});

test('busy new port leaves the working old service and files untouched', () => {
  const result = fixture('setup', 'orphan', '8443', '443', '8443');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /portBusy/);
  assert.ok(!result.trace.some(([, args]) => args[0] === 'bootout'));
  assert.deepEqual(result.deleted, []);
});

test('custom-port service still supports exact-identity uninstall and migration back to 443', () => {
  const removed = fixture('uninstall', 'orphan', undefined, '8443');
  assert.equal(removed.status, 0, removed.stderr);
  const migrated = fixture('setup', 'orphan', '443', '8443');
  assert.equal(migrated.status, 0, migrated.stderr);
  assert.ok(migrated.trace.some(([command, args]) => command === '/usr/sbin/lsof' && args.includes('-iTCP:8443')));
});

test('invalid or reserved ports are rejected before privileged actions', () => {
  for (const port of ['0', '65536', '1355', '1365', '443;id', '08443']) {
    const result = fixture('setup', 'fresh', port);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /invalidPort/);
    assert.deepEqual(result.trace, []);
    assert.deepEqual(result.deleted, []);
  }
});

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
