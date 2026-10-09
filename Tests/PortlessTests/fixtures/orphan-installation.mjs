// Test-only preload: all filesystem, network and child-process operations are virtual.
// Execute the REAL elevated entrypoints without elevation or access to real user state.
import fs from 'node:fs';
import net from 'node:net';
import childProcess from 'node:child_process';
import { EventEmitter } from 'node:events';
import { syncBuiltinESMExports } from 'node:module';
import { fileURLToPath } from 'node:url';
const real = {open: fs.openSync, read: fs.readFileSync, fstat: fs.fstatSync, close: fs.closeSync};
const sourceRoot = fileURLToPath(new URL('../../../Resources/Portless/', import.meta.url));
const isSource = file => {
  const name = file instanceof URL ? fileURLToPath(file) : String(file);
  return name.startsWith(sourceRoot) && name.endsWith('.mjs');
};
const mode = process.env.LEFTOPEN_FIXTURE_MODE;
const home = '/Users/fixture', state = `${home}/Library/Application Support/LeftOpen/Portless`;
const runtime = '/Library/Application Support/LeftOpen/Portless';
const plist = '/Library/LaunchDaemons/app.leftopen.portless.proxy.plist';
const node = `${runtime}/node-${process.arch === 'arm64' ? 'arm64' : 'x64'}`;
const args = [node, `${runtime}/package/dist/cli.js`, 'proxy', 'start', '--foreground', '--port', process.env.LEFTOPEN_FIXTURE_PORT ?? '443', '--https', '--skip-trust'];
const foreignPort = Number(process.env.LEFTOPEN_FIXTURE_FOREIGN_PORT ?? 0);
const value = {Label: 'app.leftopen.portless.proxy', ProgramArguments: args,
  EnvironmentVariables: {PORTLESS_STATE_DIR: mode === 'other-user' ? '/Users/other/state' : state}};
let loaded = !['fresh', 'dormant'].includes(mode);
let inspections = 0;
let stopRequested = false, stopChecks = 0;
const trace = [], deleted = [];
const files = new Map();
function put(file, directory, text = '') { files.set(file, {directory, text, uid: 0, mode: 0o755}); }
for (const file of ['/Users', home, `${home}/Library`, `${home}/Library/Application Support`,
  '/Library', '/Library/Application Support', '/Library/LaunchDaemons', '/private', '/private/etc']) put(file, true);
put(plist, false, JSON.stringify(value));
if (mode === 'unsafe-plist') files.get(plist).mode = 0o666;
if (['missing-plist', 'fresh'].includes(mode)) files.delete(plist);
put('/private/etc/hosts', false, '127.0.0.1 localhost\n');
function info(file) {
  if (!files.has(file)) throw Object.assign(new Error('missing'), {code: 'ENOENT'});
  const record = files.get(file);
  return {...record, gid: 0, isFile: () => !record.directory,
    isDirectory: () => record.directory, isSymbolicLink: () => false};
}
fs.lstatSync = fs.statSync = info;
fs.existsSync = file => files.has(file);
fs.readFileSync = (file, options) => {
  if (isSource(file)) return real.read(file, options);
  info(file); return files.get(file).text;
};
fs.readdirSync = directory => [...files.keys()].filter(file => file.startsWith(directory + '/') &&
  !file.slice(directory.length + 1).includes('/')).map(file => file.slice(directory.length + 1));
fs.mkdirSync = (file, options) => { put(file, true); files.get(file).mode = options?.mode ?? 0o755; };
fs.openSync = (file, flags) => {
  if (isSource(file) && (flags === 'r' || flags === 0)) return real.open(file, flags);
  info(file); return file;
};
fs.fstatSync = fd => typeof fd === 'number' ? real.fstat(fd) : info(fd);
fs.fchownSync = fs.chownSync = (file, uid) => { info(file); files.get(file).uid = uid; };
fs.fchmodSync = fs.chmodSync = (file, mode) => { info(file); files.get(file).mode = mode; };
fs.closeSync = fd => { if (typeof fd === 'number') real.close(fd); };
fs.cpSync = (source, destination) => put(destination, source.endsWith('/package'));
fs.rmSync = fs.unlinkSync = fs.rmdirSync = file => {
  deleted.push(file);
  for (const key of files.keys()) if (key === file || key.startsWith(file + '/')) files.delete(key);
};
// Any unexpected write aborts the fixture instead of touching the host.
fs.writeFileSync = fs.renameSync = () => { throw new Error('unexpectedFixtureWrite'); };
process.getuid = () => 0;
childProcess.spawnSync = (command, argv) => {
  trace.push([command, argv]);
  const ok = stdout => ({status: 0, stdout, stderr: ''});
  if (command === '/usr/bin/id') return ok('501\n');
  if (command === '/usr/bin/dscl') return ok(`NFSHomeDirectory: ${home}\n`);
  if (command === '/usr/bin/plutil') return ok(JSON.stringify(value));
  if (command === '/bin/ps') return ok(`${mode === 'wrong-process' ? 501 : 0} ${node}\n`);
  if (command === '/usr/sbin/lsof') return ok(mode === 'foreign-listener' || argv.includes(`-iTCP:${foreignPort}`) ? 'p9000\n' : 'p4478\n');
  if (command === '/bin/launchctl') {
    if (argv[0] === 'print') {
      inspections++;
      if (stopRequested) {
        stopChecks++;
        if (mode === 'verify-fails') return {status: 5, stderr: 'query failed', stdout: ''};
        if (mode === 'delayed-stop' && stopChecks >= 3) loaded = false;
      }
      if (!loaded) return {status: 113, stderr: 'Could not find service', stdout: ''};
      const pid = mode === 'pid-changed' && inspections > 1 ? 4480 : 4478;
      return ok(`system/app.leftopen.portless.proxy = {\n\tpath = ${plist}\n\tstate = running\n\tprogram = ${node}\n\targuments = {\n${args.map(arg => '\t\t' + arg).join('\n')}\n\t}\n\tenvironment = {\n\t\tPORTLESS_STATE_DIR => ${mode === 'loaded-mismatch' ? '/Users/other/state' : state}\n\t}\n\tpid = ${pid}\n}\n`);
    }
    if (argv[0] === 'bootout') {
      stopRequested = true;
      if (mode === 'stop-fails') return {status: 5, stderr: 'failed', stdout: ''};
      if (['delayed-stop', 'pending-stop', 'verify-fails'].includes(mode)) return ok('');
      if (mode === 'error-but-stopped') { loaded = false; return {status: 5, stderr: 'failed', stdout: ''}; }
      loaded = false; return ok('');
    }
    if (argv[0] === 'enable') return ok('');
  }
  if (command === node && argv[1] === 'service' && argv[2] === 'install') {
    if (loaded) throw new Error('oldServiceStillLoaded');
    args[6] = argv[argv.indexOf('--port') + 1];
    loaded = true; return ok('');
  }
  if (command === '/usr/bin/sudo' && argv.includes('verify-cert')) return {status: 1, stdout: '', stderr: ''};
  throw new Error('unexpectedFixtureCommand');
};
net.createServer = () => {
  const server = new EventEmitter();
  server.listen = (port, _host, callback) => queueMicrotask(() => {
    if ((loaded && port === Number(args[6])) || port === foreignPort) server.emit('error', Object.assign(new Error('busy'), {code: 'EADDRINUSE'}));
    else callback();
  });
  server.close = callback => callback();
  return server;
};
syncBuiltinESMExports();
process.on('exit', () => process.stdout.write('FIXTURE:' + JSON.stringify({trace, deleted}) + '\n'));
