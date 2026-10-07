// LeftOpen owns routes and lifetime; Portless owns HTTP/WebSocket forwarding.
import { createProxyServer } from './package/dist/index.js';
function validHost(name) {
  return typeof name === 'string' && name.length <= 253 && name.endsWith('.localhost')
    && name.split('.').every(label => label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label));
}
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';

const directory = process.argv[2];
const parentPID = Number(process.argv[3]);
let routes = [];
let expires = 0;
let preferredPort = 1355;
try {
  const saved = JSON.parse(fs.readFileSync(path.join(directory, 'port.json'), 'utf8'));
  if (Number.isInteger(saved) && saved >= 1355 && saved <= 1365) preferredPort = saved;
} catch {}
const candidates = [...new Set([preferredPort, ...Array.from({ length: 11 }, (_, index) => 1355 + index)])];
let proxyPort;
let server;
function liveRoutes() {
  if (Date.now() > expires) return [];
  return routes.filter(route => {
    try { process.kill(route.pid, 0); return true; } catch { return false; }
  });
}
for (const candidate of candidates) {
  server = createProxyServer({ getRoutes: liveRoutes, proxyPort: candidate, strict: true,
    onError: () => {} });
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(candidate, '127.0.0.1', resolve);
    });
    proxyPort = candidate;
    break;
  } catch (error) {
    if (error.code !== 'EADDRINUSE') throw error;
  }
}
if (proxyPort === undefined) throw new Error('All local proxy ports are occupied');
fs.writeFileSync(path.join(directory, 'port.json.tmp'), JSON.stringify(proxyPort), { mode: 0o600 });
fs.renameSync(path.join(directory, 'port.json.tmp'), path.join(directory, 'port.json'));
const ready = path.join(directory, 'ready.json');
fs.writeFileSync(ready + '.tmp', JSON.stringify({ pid: process.pid, port: proxyPort }), { mode: 0o600 });
fs.renameSync(ready + '.tmp', ready);
const input = readline.createInterface({ input: process.stdin });
input.on('line', line => {
  try {
    const update = JSON.parse(line);
    const value = update.routes;
    if (typeof update.token !== "string" || !/^[A-Fa-f0-9-]{36}$/.test(update.token)) throw new Error("Invalid token");
    if (!Array.isArray(value) || value.length > 100) throw new Error('Invalid routes');
    const names = new Set();
    for (const route of value) {
      if (!validHost(route.hostname)
          || !Number.isInteger(route.port) || route.port < 1 || route.port > 65535
          || route.port === proxyPort || !Number.isInteger(route.pid) || route.pid <= 1
          || names.has(route.hostname)) throw new Error('Invalid route');
      names.add(route.hostname);
    }
    routes = value;
    expires = Date.now() + 15000;
    fs.writeFileSync(path.join(directory, "ack.tmp"), update.token, { mode: 0o600 });
    fs.renameSync(path.join(directory, "ack.tmp"), path.join(directory, "ack"));
  } catch { routes = []; expires = 0; }
});
function stop() { routes = []; server.close(); process.exit(0); }
input.on('close', stop);
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
setInterval(() => {
  try { process.kill(parentPID, 0); } catch { stop(); }
}, 1000).unref();
