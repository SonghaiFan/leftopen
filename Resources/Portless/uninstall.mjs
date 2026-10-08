// Invoked only by the explicit native uninstall action, never by app updates.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { checkAncestors, validateTree, validateService, removingHosts, removeCertificate,
  label, runtime, plist } from './uninstall-policy.mjs';

function run(command, args) {
  return spawnSync(command, args, { encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin' } });
}
function checked(command, args, code) {
  const result = run(command, args);
  if (result.status !== 0) throw new Error(code);
  return result.stdout;
}
function exists(file) { try { fs.lstatSync(file); return true; } catch (e) { if (e.code === 'ENOENT') return false; throw e; } }
try {
  if (process.getuid() !== 0) throw new Error('authorizationRequired');
  const [home, user, uidText, fingerprint] = process.argv.slice(2);
  const uid = Number(uidText);
  if (!/^[a-zA-Z0-9_.-]+$/.test(user) || !Number.isSafeInteger(uid) || uid <= 0 ||
      !home || !path.isAbsolute(home) || path.normalize(home) !== home || home === '/') throw new Error('invalidOwner');
  if (Number(checked('/usr/bin/id', ['-u', user], 'invalidOwner').trim()) !== uid ||
      checked('/usr/bin/dscl', ['.', '-read', `/Users/${user}`, 'NFSHomeDirectory'], 'invalidOwner').trim() !== `NFSHomeDirectory: ${home}`) throw new Error('invalidOwner');
  const support = `${home}/Library/Application Support/LeftOpen`;
  const certificate = `${support}/Portless/ca.pem`;
  for (const target of [support, runtime, plist]) checkAncestors(target);
  const protectedParent = path.dirname(runtime);
  if (exists(protectedParent)) {
    const info = fs.lstatSync(protectedParent);
    if (info.uid !== 0 || (info.mode & 0o022) !== 0) throw new Error('unsafePath');
  }
  validateTree(support, [0, uid]); validateTree(runtime, [0]); validateTree(plist, [0]);
  if (exists(plist)) {
    const info = JSON.parse(checked('/usr/bin/plutil', ['-convert', 'json', '-o', '-', plist], 'unsafeService'));
    validateService(info, home);
  }
  if (exists(certificate)) {
    const actual = new crypto.X509Certificate(fs.readFileSync(certificate)).fingerprint256.replaceAll(':', '');
    if (actual !== fingerprint) throw new Error('certificateChanged');
  } else if (fingerprint !== '-' || exists(plist) || exists(runtime)) {
    // Without the original certificate we cannot identify its keychain entry safely.
    throw new Error('certificateUnavailable');
  }
  // Validate hosts before any destructive operation. Check again after service shutdown.
  checkAncestors('/private/etc/hosts');
  removingHosts(fs.readFileSync('/private/etc/hosts', 'utf8'));
  const loaded = run('/bin/launchctl', ['print', `system/${label}`]);
  if (loaded.status === 0) {
    if (!exists(plist)) throw new Error('unsafeService');
    checked('/bin/launchctl', ['bootout', `system/${label}`], 'serviceStopFailed');
    if (run('/bin/launchctl', ['print', `system/${label}`]).status === 0) throw new Error('serviceStopFailed');
  } else if (!loaded.stderr?.includes('Could not find service')) throw new Error('serviceCheckFailed');
  if (fingerprint !== '-') {
    const trust = run('/usr/bin/security', ['remove-trusted-cert', '-d', certificate]);
    if (trust.status !== 0 && !trust.stderr?.includes('specified item could not be found')) throw new Error('certificateRemovalFailed');
    removeCertificate(fingerprint, '/Library/Keychains/System.keychain', run);
  }
  const hosts = '/private/etc/hosts', original = fs.readFileSync(hosts, 'utf8'), updated = removingHosts(original);
  if (updated !== original) {
    const info = fs.statSync(hosts), temporary = `/private/etc/.leftopen-uninstall-${crypto.randomUUID()}`;
    try {
      fs.writeFileSync(temporary, updated, {flag: 'wx', mode: info.mode & 0o777});
      fs.chownSync(temporary, info.uid, info.gid);
      if (fs.readFileSync(hosts, 'utf8') !== original) throw new Error('hostsChanged');
      fs.renameSync(temporary, hosts);
    } finally { if (exists(temporary)) fs.unlinkSync(temporary); }
  }
  // All certificate operations succeeded before state (including private keys) is deleted.
  for (const target of [plist, runtime, support]) {
    if (!exists(target)) continue;
    checkAncestors(target); validateTree(target, target === support ? [0, uid] : [0]);
    fs.rmSync(target, {recursive: true});
  }
  const parent = path.dirname(runtime);
  if (exists(parent) && fs.readdirSync(parent).length === 0) fs.rmdirSync(parent);
  process.stdout.write('removed\n');
} catch (error) {
  const codes = new Set(['authorizationRequired', 'invalidOwner', 'unsafePath', 'differentOwner', 'unsafeService',
    'certificateChanged', 'certificateUnavailable', 'unsafeHosts', 'serviceStopFailed', 'serviceCheckFailed',
    'certificateRemovalFailed', 'keychainUnavailable', 'hostsChanged']);
  process.stderr.write((codes.has(error.message) ? error.message : 'cleanupFailed') + '\n');
  process.exitCode = 1;
}
