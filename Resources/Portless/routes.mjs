import { RouteStore } from './package/dist/index.js';
import fs from 'node:fs';
import path from 'node:path';
export function atomicJSON(file, value) {
  const temporary = file + '.tmp-' + process.pid;
  fs.writeFileSync(temporary, JSON.stringify(value), { mode: 0o600 });
  fs.renameSync(temporary, file);
}
export function syncRoutes(directory, desired) {
  if (!Array.isArray(desired) || desired.length > 100) throw new Error('Invalid routes');
  const hostnames = new Set();
  for (const route of desired) {
    if (typeof route.hostname !== 'string' || route.hostname.length > 253 || !route.hostname.endsWith('.localhost')
        || !route.hostname.split('.').every(label => label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label))
        || hostnames.has(route.hostname) || !Number.isInteger(route.port) || route.port < 1 || route.port > 65535
        || !Number.isInteger(route.pid) || route.pid <= 1) throw new Error('Invalid route');
    hostnames.add(route.hostname);
  }
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const store = new RouteStore(directory);
  let previous = { routes: [] };
  let managed = [];
  try { previous = JSON.parse(fs.readFileSync(path.join(directory, 'leftopen-leases.json'), 'utf8')); } catch {}
  try { managed = JSON.parse(fs.readFileSync(path.join(directory, 'leftopen-managed.json'), 'utf8')); } catch {}
  const existing = store.loadRoutes();
  // Check every collision before changing gates: another live session must remain reachable on failure.
  for (const route of desired) {
    const registered = existing.find(value => value.hostname === route.hostname);
    const old = previous.routes.find(value => value.hostname === route.hostname);
    if (registered && registered.port !== route.port && (!old || old.ownerPid !== registered.pid)) {
      throw new Error('Address belongs to a different running service');
    }
  }
  // Register the ownership gate before modifying the upstream route table.
  atomicJSON(path.join(directory, 'leftopen-managed.json'), [...new Set([...managed, ...hostnames])]);
  const leases = [];
  for (const route of desired) {
    const registered = existing.find(value => value.hostname === route.hostname);
    const old = previous.routes.find(value => value.hostname === route.hostname);
    if (registered && registered.port === route.port) {
      leases.push({ ...route, ownerPid: registered.pid });
    } else {
      if (registered && old) store.removeRoute(route.hostname, old.ownerPid);
      store.addRoute(route.hostname, route.port, route.pid); // Never --force; never signal another owner.
      leases.push({ ...route, ownerPid: route.pid });
    }
  }
  for (const old of previous.routes) {
    if (!hostnames.has(old.hostname)) store.removeRoute(old.hostname, old.ownerPid);
  }
  atomicJSON(path.join(directory, 'leftopen-leases.json'), { expiresAt: Date.now() + 15000, routes: leases });
  // Portless watches its route table; a no-op add refreshes that watcher after the lease is ready.
  for (const lease of leases) store.addRoute(lease.hostname, lease.port, lease.ownerPid);
  return leases;
}
if (process.argv[1]?.endsWith('/routes.mjs')) {
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk;
    if (input.length > 1024 * 1024) throw new Error('Input too large');
  }
  syncRoutes(process.argv[2], JSON.parse(input));
}
