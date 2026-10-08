import fs from 'node:fs';
import path from 'node:path';
import { noLinks } from './setup-policy.mjs';

export { label, runtime, plist, validateService } from './service-identity.mjs';

export function certificateCleanup(certificateExists, fingerprint, hasInstallation) {
  if (!certificateExists) {
    // Disappeared after the user-session probe: do not erase evidence of a race.
    if (fingerprint !== '-') throw new Error('certificateChanged');
    return {removeTrust: false, unresolved: hasInstallation};
  }
  if (!/^[A-F0-9]{64}$/.test(fingerprint)) throw new Error('certificateChanged');
  return {removeTrust: true, unresolved: false};
}

export function validateTree(target, owners, io = fs) {
  let info;
  try { info = io.lstatSync(target); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (info.isSymbolicLink() || !owners.includes(info.uid) ||
      (owners.length === 1 && owners[0] === 0 && (info.mode & 0o022) !== 0) ||
      (!info.isDirectory() && !info.isFile())) throw new Error('unsafePath');
  if (info.isDirectory()) for (const name of io.readdirSync(target)) validateTree(path.join(target, name), owners, io);
}

export function removingHosts(original) {
  const lines = original.split('\n'), output = [];
  let inBlock = false, blocks = 0;
  const host = '[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\\.localhost';
  const entry = new RegExp(`^(?:127\\.0\\.0\\.1|::1)\\s+(?:${host})(?:\\s+${host})*\\s*$`);
  const manual = new RegExp(`^127\\.0\\.0\\.1\\s+${host}\\s+# LeftOpen fixed address\\s*$`);
  for (const line of lines) {
    if (line === '# leftopen-portless-start') {
      if (inBlock || ++blocks > 1) throw new Error('unsafeHosts');
      inBlock = true; continue;
    }
    if (line === '# leftopen-portless-end') {
      if (!inBlock) throw new Error('unsafeHosts');
      inBlock = false; continue;
    }
    if (inBlock) {
      if (line.trim() && !entry.test(line)) throw new Error('unsafeHosts');
    } else if (!manual.test(line)) output.push(line);
  }
  if (inBlock) throw new Error('unsafeHosts');
  return output.join('\n');
}

// Missing certificates are idempotent; every other keychain error must abort cleanup.
export function removeCertificate(fingerprint, keychain, run) {
  if (!/^[A-F0-9]{64}$/.test(fingerprint)) throw new Error('invalidCertificate');
  const listing = run('/usr/bin/security', ['find-certificate', '-a', '-Z', keychain]);
  if (listing.status !== 0) throw new Error('keychainUnavailable');
  if (!listing.stdout.split('\n').some(line => line.trim() === `SHA-256 hash: ${fingerprint}`)) return;
  const removal = run('/usr/bin/security', ['delete-certificate', '-t', '-Z', fingerprint, keychain]);
  if (removal.status !== 0) throw new Error('certificateRemovalFailed');
  const after = run('/usr/bin/security', ['find-certificate', '-a', '-Z', keychain]);
  if (after.status !== 0 || after.stdout.includes(fingerprint)) throw new Error('certificateRemovalFailed');
}

export function checkAncestors(target, io = fs) {
  let current = path.dirname(target);
  while (current !== '/') {
    try {
      const info = io.lstatSync(current);
      if (info.isSymbolicLink() || !info.isDirectory()) throw new Error('unsafePath');
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    current = path.dirname(current);
  }
  noLinks(target, io);
}
