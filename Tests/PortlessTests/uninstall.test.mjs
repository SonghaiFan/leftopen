import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { validateService, validateTree, removingHosts, removeCertificate, checkAncestors, certificateCleanup,
  label, runtime } from '../../Resources/Portless/uninstall-policy.mjs';

const home = '/Users/fixture';
const service = () => ({Label: label, ProgramArguments: [`${runtime}/node-arm64`, `${runtime}/package/dist/cli.js`,
  'proxy', 'start', '--foreground', '--port', '443', '--https', '--skip-trust'],
  EnvironmentVariables: {PORTLESS_STATE_DIR: `${home}/Library/Application Support/LeftOpen/Portless`}});

test('service removal requires the exact runtime, label and original user state directory', () => {
  validateService(service(), home);
  for (const value of [{...service(), Label: 'sh.portless.proxy'},
    {...service(), ProgramArguments: ['/opt/homebrew/bin/node', `${runtime}/package/dist/cli.js`]},
    {...service(), EnvironmentVariables: {PORTLESS_STATE_DIR: '/Users/other/Library/Application Support/LeftOpen/Portless'}},
    {...service(), ProgramArguments: [`${runtime}/node-arm64`, '/tmp/project.js']}]) {
    assert.throws(() => validateService(value, home), /differentOwner/);
  }
});

test('missing original certificate permits service cleanup but never keychain deletion', () => {
  assert.deepEqual(certificateCleanup(false, '-', true), {removeTrust: false, unresolved: true});
  assert.deepEqual(certificateCleanup(false, '-', false), {removeTrust: false, unresolved: false});
  assert.deepEqual(certificateCleanup(true, 'A'.repeat(64), true), {removeTrust: true, unresolved: false});
  assert.throws(() => certificateCleanup(false, 'A'.repeat(64), true), /certificateChanged/);
  assert.throws(() => certificateCleanup(true, '-', true), /certificateChanged/);
});

test('remove only LeftOpen hosts entries, preserving unrelated Portless and user mappings', () => {
  const untouched = '127.0.0.1 localhost\n# portless-start\n127.0.0.1 other.localhost\n# portless-end\n127.0.0.1 personal.localhost\n';
  const original = untouched + '# leftopen-portless-start\n127.0.0.1 alpha.localhost beta.localhost\n::1 alpha.localhost\n# leftopen-portless-end\n127.0.0.1 legacy.localhost # LeftOpen fixed address\n';
  assert.equal(removingHosts(original), untouched);
  assert.equal(removingHosts(untouched), untouched);
});

test('malformed or unexpected owned blocks abort instead of discarding user edits', () => {
  for (const value of ['# leftopen-portless-start\n', '# leftopen-portless-end\n',
    '# leftopen-portless-start\n192.168.1.2 private.example\n# leftopen-portless-end\n',
    '# leftopen-portless-start\n127.0.0.1 unrelated.example\n# leftopen-portless-end\n',
    '# leftopen-portless-start\n# leftopen-portless-start\n# leftopen-portless-end\n']) {
    assert.throws(() => removingHosts(value), /unsafeHosts/);
  }
});

test('certificate removal targets only matching fingerprint and verifies disappearance', () => {
  const fingerprint = 'A'.repeat(64), other = 'B'.repeat(64), commands = [];
  let present = true;
  removeCertificate(fingerprint, '/fixture.keychain', (command, args) => {
    commands.push(args);
    if (args[0] === 'delete-certificate') { present = false; return {status: 0}; }
    return {status: 0, stdout: `SHA-256 hash: ${other}\n` + (present ? `SHA-256 hash: ${fingerprint}\n` : '')};
  });
  assert.deepEqual(commands[1], ['delete-certificate', '-t', '-Z', fingerprint, '/fixture.keychain']);
  let deleted = false;
  removeCertificate(fingerprint, '/fixture.keychain', (_, args) => {
    if (args[0] === 'delete-certificate') deleted = true;
    return {status: 0, stdout: `SHA-256 hash: ${other}\n`};
  });
  assert.equal(deleted, false);
});

test('locked keychain and cancelled deletion remain failures; state must be retained', () => {
  const fingerprint = 'A'.repeat(64);
  assert.throws(() => removeCertificate(fingerprint, '/fixture', () => ({status: 1})), /keychainUnavailable/);
  assert.throws(() => removeCertificate(fingerprint, '/fixture', (_, args) => args[0] === 'find-certificate'
    ? {status: 0, stdout: `SHA-256 hash: ${fingerprint}\n`} : {status: 1}), /certificateRemovalFailed/);
  assert.throws(() => removeCertificate('common name', '/fixture', () => assert.fail()), /invalidCertificate/);
});

test('real filesystem rejects nested, dangling and ancestor symlinks without touching targets', t => {
  const directory = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'leftopen-uninstall-test-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  fs.mkdirSync(path.join(directory, 'state'));
  fs.writeFileSync(path.join(directory, 'outside'), 'keep');
  validateTree(path.join(directory, 'state'), [process.getuid()]);
  fs.symlinkSync(path.join(directory, 'outside'), path.join(directory, 'state/ca.pem'));
  assert.throws(() => validateTree(path.join(directory, 'state'), [process.getuid()]), /unsafePath/);
  assert.throws(() => checkAncestors(path.join(directory, 'state')), /unsafePath/);
  fs.symlinkSync('/nonexistent', path.join(directory, 'dangling'));
  assert.throws(() => validateTree(path.join(directory, 'dangling'), [process.getuid()]), /unsafePath/);
  fs.symlinkSync(path.join(directory, 'state'), path.join(directory, 'linked'));
  assert.throws(() => checkAncestors(path.join(directory, 'linked/file')), /unsafePath/);
  assert.equal(fs.readFileSync(path.join(directory, 'outside'), 'utf8'), 'keep');
  validateTree(path.join(directory, 'absent'), [process.getuid()]);
  checkAncestors(path.join(directory, 'absent/nested/state'));
});

test('reject another owner without mutation', t => {
  const directory = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'leftopen-owner-test-'));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  assert.throws(() => validateTree(directory, [process.getuid() + 1]), /unsafePath/);
  assert.ok(fs.statSync(directory).isDirectory());
});

test('privileged entry refuses non-root execution before accessing installation files', () => {
  if (process.getuid() === 0) return;
  const result = spawnSync(process.execPath, ['Resources/Portless/uninstall.mjs', home, 'fixture', '501', '-'], {encoding: 'utf8'});
  assert.equal(result.status, 1);
  assert.equal(result.stderr.trim(), 'authorizationRequired');
});
