// Root-owned launchd metadata is the recovery authority, not a user-writable PID file.
import fs from 'node:fs';
import { commandDiagnostic } from './diagnostics.mjs';
import { proxyPort } from './proxy-config.mjs';
export const label = 'app.leftopen.portless.proxy';
export const runtime = '/Library/Application Support/LeftOpen/Portless';
export const plist = `/Library/LaunchDaemons/${label}.plist`;
const target = `system/${label}`;

export function validateService(value, home) {
  const args = value.ProgramArguments;
  let port;
  try { port = proxyPort(args?.[6]); } catch { throw new Error('differentOwner'); }
  const tail = [`${runtime}/package/dist/cli.js`, 'proxy', 'start', '--foreground', '--port', String(port), '--https', '--skip-trust'];
  if (value.Label !== label || !Array.isArray(args) ||
      ![`${runtime}/node-arm64`, `${runtime}/node-x64`].includes(args[0]) ||
      JSON.stringify(args.slice(1)) !== JSON.stringify(tail) ||
      (value.EnvironmentVariables?.PORTLESS_PORT !== undefined && value.EnvironmentVariables.PORTLESS_PORT !== String(port)) ||
      value.EnvironmentVariables?.PORTLESS_STATE_DIR !== `${home}/Library/Application Support/LeftOpen/Portless`) {
    throw new Error('differentOwner');
  }
  return args;
}

function successful(result) { return result.status === 0 && !result.error && !result.signal; }
function absent(result) {
  return !result.error && !result.signal && result.status !== 0 &&
    /Could not find service/.test(result.stderr ?? '');
}

export function ownedService(home, run, io = fs) {
  let info;
  try { info = io.lstatSync(plist); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  let args;
  if (info) {
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== 0 || (info.mode & 0o022)) throw new Error('unsafeService');
    const decoded = run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', plist]);
    if (!successful(decoded)) throw new Error('unsafeService');
    try { args = validateService(JSON.parse(decoded.stdout), home); }
    catch (error) { throw new Error(error.message === 'differentOwner' ? 'differentOwner' : 'unsafeService'); }
  }
  const loaded = run('/bin/launchctl', ['print', target]);
  if (absent(loaded)) return null;
  if (!successful(loaded)) {
    commandDiagnostic('launchd.inspect', loaded);
    throw new Error('serviceCheckFailed');
  }
  if (!args) throw new Error('unsafeService');
  const text = loaded.stdout;
  const field = key => {
    const matches = [...text.matchAll(new RegExp(`^\\t${key} = (.+)$`, 'gm'))];
    return matches.length === 1 ? matches[0][1].trim() : null;
  };
  const loadedArgs = text.match(/^\targuments = \{\n([\s\S]*?)^\t\}/m)?.[1]
    .split('\n').map(line => line.trim()).filter(Boolean);
  const directory = `${home}/Library/Application Support/LeftOpen/Portless`;
  // Check loaded state too: a matching plist alone does not identify a previously loaded job.
  const environments = [...text.matchAll(/^\t\tPORTLESS_STATE_DIR => (.*)$/gm)];
  if (!text.startsWith(`${target} = {\n`) || field('path') !== plist || field('program') !== args[0] ||
      JSON.stringify(loadedArgs) !== JSON.stringify(args) || environments.length !== 1 ||
      environments[0][1] !== directory) throw new Error('unsafeService');
  const pidText = field('pid');
  const pid = pidText === null ? null : Number(pidText);
  if (pid !== null) {
    if (!Number.isSafeInteger(pid) || pid <= 1) throw new Error('unsafeService');
    const process = run('/bin/ps', ['-p', String(pid), '-o', 'uid=,comm=']);
    const match = process.stdout?.trim().match(/^(\d+)\s+(.+)$/);
    if (!successful(process) || !match || Number(match[1]) !== 0 || match[2] !== args[0]) throw new Error('unsafeService');
  } else if (field('state') === 'running') throw new Error('unsafeService');
  return {pid, executable: args[0], port: Number(args[6])};
}

export function assertOwnedHTTPSListener(service, run, port = service?.port ?? 443) {
  if (!service?.pid || service.port !== port) throw new Error('portBusy');
  const result = run('/usr/sbin/lsof', ['-nP', '-a', `-iTCP:${port}`, '-sTCP:LISTEN', '-Fp']);
  if (!successful(result)) throw new Error('portBusy');
  const pids = result.stdout.split('\n').filter(line => /^p\d+$/.test(line)).map(line => Number(line.slice(1)));
  if (!pids.length || pids.some(pid => pid !== service.pid)) throw new Error('portBusy');
}

export async function stopOwnedService(home, expected, run, io = fs) {
  if (!expected) return;
  const current = ownedService(home, run, io);
  if (JSON.stringify(current) !== JSON.stringify(expected)) throw new Error('serviceChanged');
  // Target the verified launchd job, never kill a PID read from user state.
  const stopped = run('/bin/launchctl', ['bootout', target]);
  commandDiagnostic('launchd.bootout', stopped);
  // bootout can return before launchd unregisters the job. Final state, not just
  // the command exit code, determines success. Never repeat bootout or kill a PID.
  for (let attempt = 0; attempt <= 50; attempt++) {
    const check = run('/bin/launchctl', ['print', target]);
    if (absent(check)) return;
    if (!successful(check)) {
      commandDiagnostic('launchd.verifyStopped', check);
      throw new Error('stopVerificationFailed');
    }
    if (attempt === 50) {
      commandDiagnostic('launchd.verifyStopped', check);
      throw new Error(successful(stopped) ? 'serviceStopPending' : 'serviceStopFailed');
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
}
