import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { noLinks, repairUserDirectories, installAddressService, checkedSetupResult } from '../../Resources/Portless/setup-policy.mjs';

const uid = process.getuid(), gid = process.getgid();
function fixture(t) {
  const home = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'leftopen-setup-test-'));
  fs.mkdirSync(path.join(home, 'Library/Application Support'), { recursive: true, mode: 0o755 });
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  return { home, parent: path.join(home, 'Library/Application Support/LeftOpen'),
    directory: path.join(home, 'Library/Application Support/LeftOpen/Portless') };
}
const mode = file => fs.statSync(file).mode & 0o777;

test('fresh install creates BOTH private user-owned directories without altering ancestors', t => {
  const {home, parent, directory} = fixture(t);
  const support = path.dirname(parent), before = fs.statSync(support);
  assert.equal(repairUserDirectories(home, uid, gid), directory);
  for (const file of [parent, directory]) {
    assert.equal(fs.statSync(file).uid, uid);
    assert.equal(mode(file), 0o700);
  }
  assert.equal(fs.statSync(support).mode, before.mode);
  assert.equal(fs.statSync(support).uid, before.uid);
});

test('root-owned parent repair targets only two directory descriptors, never descendants', t => {
  const {home, parent, directory} = fixture(t);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const key = path.join(directory, 'ca-key.pem');
  fs.writeFileSync(key, 'fixture', {mode: 0o600});
  const mutations = [], descriptors = new Map();
  // Simulate the historic root owner; real chmod and inode access still run on macOS.
  const rootInfo = info => Object.assign(Object.create(info), {uid: 0});
  const io = {...fs,
    lstatSync: file => [parent, directory].includes(file) ? rootInfo(fs.lstatSync(file)) : fs.lstatSync(file),
    openSync: (file, flags) => { const fd = fs.openSync(file, flags); descriptors.set(fd, file); return fd; },
    fstatSync: fd => rootInfo(fs.fstatSync(fd)),
    fchownSync: (fd, u, g) => { mutations.push([descriptors.get(fd), u, g]); fs.fchownSync(fd, u, g); }
  };
  repairUserDirectories(home, uid, gid, io);
  assert.deepEqual(mutations, [[parent, uid, gid], [directory, uid, gid]]);
  assert.equal(mode(key), 0o600);
  assert.equal(fs.readFileSync(key, 'utf8'), 'fixture');
  repairUserDirectories(home, uid, gid);
  assert.equal(mode(key), 0o600);
});

test('reject links, including dangling ones, before changing directories', t => {
  const {home, parent, directory} = fixture(t);
  fs.mkdirSync(directory, {recursive: true, mode: 0o755});
  fs.symlinkSync('/nonexistent-leftopen-test-target', path.join(directory, 'ca.pem'));
  assert.throws(() => repairUserDirectories(home, uid, gid), /unsafePath/);
  assert.equal(mode(parent), 0o755);
  assert.throws(() => noLinks(path.join(directory, 'ca.pem')), /unsafePath/);
});

test('refuse other-user ownership before any directory mutation', t => {
  const {home, parent, directory} = fixture(t);
  fs.mkdirSync(directory, {recursive: true, mode: 0o755});
  const io = {...fs, lstatSync: file => {
    const info = fs.lstatSync(file);
    return file === directory ? Object.assign(Object.create(info), {uid: uid + 10000}) : info;
  }, fchownSync: () => assert.fail('must not mutate')};
  assert.throws(() => repairUserDirectories(home, uid, gid, io), /differentOwner/);
  assert.equal(mode(parent), 0o755);
});

test('symlink parent cannot redirect ownership repair to another folder', t => {
  const {home, parent} = fixture(t);
  const unrelated = path.join(home, 'unrelated');
  fs.mkdirSync(unrelated, {mode: 0o755});
  fs.symlinkSync(unrelated, parent);
  assert.throws(() => repairUserDirectories(home, uid, gid), /unsafePath/);
  assert.equal(mode(unrelated), 0o755);
});

test('disabled service is enabled before upstream install, and failures stop installation', () => {
  let disabled = true;
  const calls = [];
  installAddressService('/node', '/cli', '/state', {}, (command, args) => {
    calls.push([command, args]);
    if (command === '/bin/launchctl') { disabled = false; return {status: 0}; }
    assert.equal(disabled, false, 'bootstrap must be possible before install');
    return {status: 0};
  });
  assert.deepEqual(calls[0], ['/bin/launchctl', ['enable', 'system/app.leftopen.portless.proxy']]);
  assert.equal(calls.length, 2);
  let count = 0;
  assert.throws(() => installAddressService('/node', '/cli', '/state', {}, () => {
    count++; return {status: 5, stderr: 'private diagnostic'};
  }), /^Error: launchdEnableFailed:exit_5$/);
  assert.equal(count, 1);
});

test('setup errors expose a bounded stage and exit code, never raw stderr', () => {
  assert.throws(() => checkedSetupResult({status: 1, stderr: 'secret path/token'}, 'serviceInstallFailed'),
    /^Error: serviceInstallFailed:exit_1$/);
  assert.throws(() => checkedSetupResult({status: null, error: {code:'ETIMEDOUT'}}, 'serviceInstallFailed'),
    /^Error: serviceInstallFailed:timeout$/);
});

test('macOS launchd disabled bootstrap recovers using enable first (isolated user agent)',
  {skip: process.platform !== 'darwin' || process.env.LEFTOPEN_TEST_LAUNCHD !== '1'}, t => {
    const {home} = fixture(t);
    const label = `app.leftopen.test.${process.pid}.${Date.now()}`;
    const domain = `gui/${uid}`, target = `${domain}/${label}`, plist = path.join(home, 'agent.plist');
    fs.writeFileSync(plist, `<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>${label}</string><key>ProgramArguments</key><array><string>/usr/bin/true</string></array></dict></plist>`);
    const launch = args => spawnSync('/bin/launchctl', args, {encoding:'utf8', timeout:10000});
    t.after(() => { launch(['enable', target]); launch(['bootout', domain, plist]); });
    assert.equal(launch(['disable', target]).status, 0);
    assert.notEqual(launch(['bootstrap', domain, plist]).status, 0);
    installAddressService('/test-node', '/cli', '/state', {}, (command, args) => {
      if (command === '/bin/launchctl') {
        assert.deepEqual(args, ['enable', 'system/app.leftopen.portless.proxy']);
        return launch(['enable', target]);
      }
      return launch(['bootstrap', domain, plist]);
    });
    assert.equal(launch(['print', target]).status, 0);
  });
