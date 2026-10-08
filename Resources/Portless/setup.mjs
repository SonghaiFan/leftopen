// This single authorized action installs the upstream service using a root-owned runtime.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { spawnSync } from 'node:child_process';
import { noLinks, repairUserDirectories, installAddressService } from './setup-policy.mjs';
const label = 'app.leftopen.portless.proxy';
const protectedRoot = '/Library/Application Support/LeftOpen/Portless';
const plist = `/Library/LaunchDaemons/${label}.plist`;
function fail(code) { process.stderr.write(code + '\n'); process.exit(1); }
if (process.getuid() !== 0) fail('authorizationRequired');
const [source, home, user, uidText, gidText] = process.argv.slice(2);
if (!source || !home || !/^[a-zA-Z0-9_.-]+$/.test(user) || !/^[0-9]+$/.test(uidText) || Number(uidText) === 0) fail('invalidOwner');
const uid = Number(uidText), gid = Number(gidText);
const identity = spawnSync('/usr/bin/id', ['-u', user], { encoding: 'utf8' });
if (identity.status !== 0 || Number(identity.stdout.trim()) !== uid || !Number.isInteger(gid)) fail('invalidOwner');
const directory = path.join(home, 'Library/Application Support/LeftOpen/Portless');
// Reject links before elevated file operations, including preexisting certificate/state files.
for (const file of [home, path.join(home, 'Library'), path.join(home, 'Library/Application Support'),
  path.join(home, 'Library/Application Support/LeftOpen'), '/Library/Application Support/LeftOpen', plist]) {
  try { if (fs.lstatSync(file).isSymbolicLink()) fail('unsafePath'); }
  catch (error) { if (error.code !== 'ENOENT') fail('unsafePath'); }
}
try { noLinks(directory); noLinks(protectedRoot); }
catch { fail('unsafePath'); }
if (fs.existsSync(plist) && !fs.readFileSync(plist, 'utf8').includes(directory)) fail('differentOwner');
const nodeName = process.arch === 'arm64' ? 'node-arm64' : 'node-x64';
const protectedNode = path.join(protectedRoot, nodeName);
const protectedParent = path.dirname(protectedRoot);
if (fs.existsSync(protectedParent) && fs.statSync(protectedParent).uid !== 0) fail('unsafeRuntime');
if (fs.existsSync(protectedRoot) && (fs.lstatSync(protectedRoot).isSymbolicLink() || fs.statSync(protectedRoot).uid !== 0)) fail('unsafeRuntime');
// Refuse to replace an unrelated listener, including external Portless.
let portBusy = false;
const probe = net.createServer();
await new Promise(resolve => {
  probe.once('error', () => { portBusy = true; resolve(); });
  probe.listen(443, '127.0.0.1', () => probe.close(resolve));
});
if (portBusy) {
  let owned = false;
  try {
    const pid = Number(fs.readFileSync(path.join(directory, 'proxy.pid'), 'utf8').trim());
    const check = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'comm='], { encoding: 'utf8' });
    owned = check.status === 0 && check.stdout.trim() === protectedNode && fs.existsSync(plist);
  } catch {}
  if (!owned) fail('portBusy');
}
// A forged or stale PID file must never make an elevated Portless stop signal another process.
try {
  const pidFile = path.join(directory, 'proxy.pid');
  const pid = Number(fs.readFileSync(pidFile, 'utf8').trim());
  const check = spawnSync('/bin/ps', ['-p', String(pid), '-o', 'comm='], { encoding: 'utf8' });
  if (check.status !== 0) fs.unlinkSync(pidFile);
  else if (check.stdout.trim() !== protectedNode) fail('differentOwner');
} catch (error) { if (error.code !== 'ENOENT') fail('setupFailed'); }
try { repairUserDirectories(home, uid, gid); }
catch (error) { fail(['unsafePath', 'differentOwner', 'invalidOwner'].includes(error.message)
  ? error.message : 'userDirectoryRepairFailed'); }
fs.mkdirSync(protectedRoot, { recursive: true, mode: 0o755 });
// Copy only the verified package and helpers, never a project script or shell profile.
for (const name of ['package', nodeName, 'lease-gate.mjs', 'PORTLESS-LICENSE', `NODE-LICENSE-${process.arch === 'arm64' ? 'arm64' : 'x64'}`, 'LEFTOPEN-NOTICE']) {
  const destination = path.join(protectedRoot, name);
  if (fs.existsSync(destination)) fs.rmSync(destination, { recursive: true });
  fs.cpSync(path.join(source, name), destination, { recursive: true, dereference: false });
}
function protect(file) {
  if (fs.lstatSync(file).isSymbolicLink()) fail('unsafeRuntime');
  fs.chownSync(file, 0, 0);
  const directory = fs.statSync(file).isDirectory();
  fs.chmodSync(file, directory || file === protectedNode ? 0o755 : 0o644);
  if (directory) for (const name of fs.readdirSync(file)) protect(path.join(file, name));
}
protect(protectedRoot);
const env = { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', HOME: home, SUDO_USER: user,
  SUDO_UID: String(uid), SUDO_GID: String(gid), PORTLESS_STATE_DIR: directory,
  PORTLESS_SYNC_HOSTS: '1', PORTLESS_HTTPS: '1', PORTLESS_PORT: '443', PORTLESS_LAN: '0',
  PORTLESS_TLD: 'localhost', NO_COLOR: '1' };
const cli = path.join(protectedRoot, 'package/dist/cli.js');
try { installAddressService(protectedNode, cli, directory, env, spawnSync); }
catch (error) { fail(error.message); }
// Verify trust as the browser's user, rather than accepting a marker as proof.
const trust = spawnSync('/usr/bin/sudo', ['-u', user, '/usr/bin/security', 'verify-cert', '-c', path.join(directory, 'ca.pem'), '-L', '-p', 'ssl'],
  { env, encoding: 'utf8', timeout: 30000 });
// The native app completes trust in the GUI user's authorization session when needed.
// Service installation and certificate trust are separate readiness checks.
process.stdout.write(trust.status === 0 ? 'ready\n' : 'trustRequired\n');
