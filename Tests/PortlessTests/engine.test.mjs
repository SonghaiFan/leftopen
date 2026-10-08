import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { addingHosts } from '../../Resources/Portless/hosts.mjs';
const runtime = path.resolve('.build/portless-runtime');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(check) {
  for (let i = 0; i < 120; i++) { const value = check(); if (value) return value; await delay(25); }
  throw new Error('Timed out');
}
async function engine(t, parentPID = process.pid, directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leftopen-engine-test-'))) {
  const child = spawn(process.execPath, [path.join(runtime, 'engine.mjs'), directory, String(parentPID)],
    { stdio: ['pipe', 'ignore', 'pipe'], env: { PATH: '/usr/bin:/bin' } });
  let error = ''; child.stderr.on('data', data => { error += data.toString(); });
  t.after(async () => {
    child.stdin.end();
    if (child.exitCode === null) child.kill();
    await delay(50);
    fs.rmSync(directory, { recursive: true, force: true });
  });
  const ready = await waitFor(() => {
    if (child.exitCode !== null) throw new Error(error || 'Engine exited');
    try { const state = JSON.parse(fs.readFileSync(path.join(directory, 'ready.json'), 'utf8')); return state.pid === child.pid ? state : null; } catch { return null; }
  });
  async function update(routes) {
    const token = crypto.randomUUID();
    child.stdin.write(JSON.stringify({ token, routes }) + '\n');
    await waitFor(() => { try { return fs.readFileSync(path.join(directory, 'ack'), 'utf8') === token; } catch { return false; } });
  }
  return { child, port: ready.port, update, directory };
}
async function request(port, host = 'test.localhost') {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, headers: { Host: `${host}:${port}` }, timeout: 2000 }, res => {
      let body = ''; res.on('data', data => { body += data; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', reject); req.on('timeout', () => req.destroy(new Error('timeout')));
  });
}

// Reserve a preferred proxy port without taking over an existing user service.
async function blockedEngineState(t) {
  for (let port = 1355; port <= 1365; port++) {
    const blocker = net.createServer();
    try {
      blocker.listen(port, '127.0.0.1'); await once(blocker, 'listening');
    } catch (error) {
      if (error.code === 'EADDRINUSE') continue;
      throw error;
    }
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'leftopen-engine-test-'));
    fs.writeFileSync(path.join(directory, 'port.json'), JSON.stringify(port));
    t.after(() => {
      if (blocker.listening) blocker.close();
      fs.rmSync(directory, {recursive: true, force: true});
    });
    return {blocker, port, directory};
  }
  throw new Error('No free proxy test port; existing listeners were left untouched');
}

test('hosts setup preserves other entries, is idempotent, and refuses conflicting DNS', () => {
  const original = '127.0.0.1 localhost\n# portless managed\n127.0.0.1 external.localhost\n';
  const updated = addingHosts(original, ['my--app.localhost']);
  assert.ok(updated.startsWith(original));
  assert.equal(addingHosts(updated, ['my--app.localhost']), updated);
  assert.throws(() => addingHosts('10.0.0.1 test.localhost\n', ['test.localhost']));
  for (const name of ['bad;name.localhost', 'a..localhost', '-bad.localhost', 'remote.com', 'a\nlocalhost']) {
    assert.throws(() => addingHosts(original, [name]));
  }
});

test('real Portless HTTP and WebSocket forwarding, updates, removal, and child shutdown', async t => {
  const backend = http.createServer((req, res) => res.end(`backend:${req.headers.host}`));
  backend.on('upgrade', (req, socket) => {
    const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
  });
  backend.listen(0, '127.0.0.1'); await once(backend, 'listening');
  t.after(() => backend.close());
  const instance = await engine(t);
  await instance.update([{ hostname: 'test.localhost', port: backend.address().port, pid: process.pid }]);
  const response = await request(instance.port);
  assert.equal(response.status, 200);
  assert.equal(response.headers['x-portless'], '1');
  assert.equal(response.body, `backend:test.localhost:${instance.port}`);
  assert.equal((await request(instance.port, 'unregistered.localhost')).status, 404);
  const socket = net.createConnection(instance.port, '127.0.0.1');
  await once(socket, 'connect');
  socket.write(`GET / HTTP/1.1\r\nHost: test.localhost:${instance.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`);
  const [data] = await once(socket, 'data');
  assert.match(data.toString(), /101 Switching Protocols/); socket.destroy();
  await instance.update([]);
  assert.equal((await request(instance.port)).status, 404);
  const exited = once(instance.child, 'exit'); instance.child.stdin.end(); await exited;
  assert.equal(instance.child.exitCode, 0);
});

test('IPv6-only upstream and dead route owners', async t => {
  const backend = http.createServer((req, res) => res.end('ipv6'));
  backend.listen(0, '::1'); await once(backend, 'listening'); t.after(() => backend.close());
  const instance = await engine(t);
  await instance.update([{ hostname: 'test.localhost', port: backend.address().port, pid: process.pid }]);
  assert.equal((await request(instance.port)).body, 'ipv6');
  await instance.update([{ hostname: 'test.localhost', port: backend.address().port, pid: 2147483647 }]);
  assert.equal((await request(instance.port)).status, 404);
});

test('occupied proxy port is preserved, and parent death stops the proxy', async t => {
  const {blocker, port, directory} = await blockedEngineState(t);
  const instance = await engine(t, 2147483647, directory);
  assert.notEqual(instance.port, port);
  const exited = once(instance.child, 'exit'); await exited;
  assert.equal(instance.child.exitCode, 0);
  assert.equal(blocker.listening, true);
});

test('route lease expires if the app stops refreshing', async t => {
  const backend = http.createServer((req, res) => res.end('live'));
  backend.listen(0, '127.0.0.1'); await once(backend, 'listening'); t.after(() => backend.close());
  const instance = await engine(t);
  await instance.update([{ hostname: 'test.localhost', port: backend.address().port, pid: process.pid }]);
  assert.equal((await request(instance.port)).status, 200);
  await delay(15100);
  assert.equal((await request(instance.port)).status, 404);
});

test('selected proxy port survives a restart after a temporary conflict clears', async t => {
  const {blocker, port, directory} = await blockedEngineState(t);
  const first = await engine(t, process.pid, directory);
  assert.notEqual(first.port, port);
  const firstExit = once(first.child, 'exit'); first.child.stdin.end(); await firstExit;
  await new Promise(resolve => blocker.close(resolve));
  const second = await engine(t, process.pid, first.directory);
  assert.equal(second.port, first.port);
});
