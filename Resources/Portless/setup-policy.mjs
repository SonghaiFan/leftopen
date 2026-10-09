import fs from 'node:fs';
import path from 'node:path';
import { commandDiagnostic } from './diagnostics.mjs';
import { proxyPort } from './proxy-config.mjs';

function statIfPresent(file, io) {
  try { return io.lstatSync(file); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

// lstat also detects dangling links. Never follow links during elevated setup.
export function noLinks(file, io = fs) {
  const info = statIfPresent(file, io);
  if (!info) return;
  if (info.isSymbolicLink()) throw new Error('unsafePath');
  if (info.isDirectory()) for (const item of io.readdirSync(file)) noLinks(path.join(file, item), io);
}

export function repairUserDirectories(home, uid, gid, io = fs) {
  if (!path.isAbsolute(home) || path.normalize(home) !== home || home === '/' ||
      !Number.isSafeInteger(uid) || uid <= 0 || !Number.isSafeInteger(gid) || gid < 0) {
    throw new Error('invalidOwner');
  }
  const support = path.join(home, 'Library/Application Support');
  // These ancestors are not ours to create, chmod, or chown.
  for (const ancestor of [home, path.join(home, 'Library'), support]) {
    const info = io.lstatSync(ancestor);
    if (info.isSymbolicLink() || !info.isDirectory()) throw new Error('unsafePath');
  }
  const parent = path.join(support, 'LeftOpen');
  const directory = path.join(parent, 'Portless');
  // Check BOTH targets and the existing state tree before changing either owner.
  for (const target of [parent, directory]) {
    const info = statIfPresent(target, io);
    if (info && (info.isSymbolicLink() || !info.isDirectory())) throw new Error('unsafePath');
    if (info && info.uid !== 0 && info.uid !== uid) throw new Error('differentOwner');
  }
  noLinks(directory, io);
  for (const target of [parent, directory]) {
    if (!statIfPresent(target, io)) io.mkdirSync(target, { mode: 0o700 });
    // Open without following links and verify the opened inode before mutation.
    const fd = io.openSync(target, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
    try {
      const info = io.fstatSync(fd);
      if (!info.isDirectory()) throw new Error('unsafePath');
      if (info.uid !== 0 && info.uid !== uid) throw new Error('differentOwner');
      io.fchownSync(fd, uid, gid);
      io.fchmodSync(fd, 0o700);
    } finally { io.closeSync(fd); }
  }
  return directory;
}

// Only machine-readable stage/status is exposed; never forward child stderr, paths or env.
export function checkedSetupResult(result, stage) {
  if (result.status === 0 && !result.error && !result.signal) return;
  commandDiagnostic(stage === 'launchdEnableFailed' ? 'launchd.enable' : 'service.install', result);
  const detail = result.error?.code === 'ETIMEDOUT' ? 'timeout'
    : Number.isInteger(result.status) ? `exit_${result.status}` : 'failed';
  throw new Error(`${stage}:${detail}`);
}

export function installAddressService(node, cli, directory, env, spawn) {
  const port = proxyPort(env.PORTLESS_PORT);
  // launchd refuses bootstrap for a disabled label. Enable only LeftOpen's label first.
  checkedSetupResult(spawn('/bin/launchctl', ['enable', 'system/app.leftopen.portless.proxy'],
    { env, encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 }), 'launchdEnableFailed');
  checkedSetupResult(spawn(node, [cli, 'service', 'install', '--state-dir', directory, '--https', '--port', String(port)],
    { env, encoding: 'utf8', timeout: 120000, maxBuffer: 1024 * 1024 }), 'serviceInstallFailed');
}
