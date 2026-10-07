// LeftOpen addition to the pinned Portless CLI: fail closed when native observations expire.
import fs from 'node:fs';
import path from 'node:path';
export function gateRoutes(routes, directory, now = Date.now(), alive = pid => {
  if (pid === 0) return true;
  try { process.kill(pid, 0); return true; } catch { return false; }
}) {
  let managed;
  let leases;
  try {
    managed = new Set(JSON.parse(fs.readFileSync(path.join(directory, 'leftopen-managed.json'), 'utf8')));
    leases = JSON.parse(fs.readFileSync(path.join(directory, 'leftopen-leases.json'), 'utf8'));
  } catch {
    // This is a private LeftOpen namespace. Missing observation files never permit stale forwarding.
    return [];
  }
  return routes.filter(route => {
    if (!alive(route.pid)) return false;
    if (!managed.has(route.hostname)) return true; // Portless-started session owns its lifecycle.
    const lease = leases.routes?.find(value => value.hostname === route.hostname);
    return leases.expiresAt > now && lease?.ownerPid === route.pid && lease?.port === route.port
      && alive(lease.pid);
  });
}
