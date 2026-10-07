// A narrowly scoped, optional macOS authorization action for Safari DNS.
import fs from 'node:fs';
import crypto from 'node:crypto';
function validHost(name) {
  return typeof name === 'string' && name.length <= 253 && name.endsWith('.localhost')
    && name.split('.').every(label => label.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label));
}
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function addingHosts(original, names) {
  if (!names.length || names.length > 100 || names.some(name =>
    !validHost(name))) {
    throw new Error('Invalid local hostname');
  }
  let result = original;
  for (const name of names) {
    const lines = result.split('\n').map(line => line.split('#')[0].trim().split(/\s+/));
    const entries = lines.filter(parts => parts.slice(1).includes(name));
    if (entries.some(parts => parts[0] !== '127.0.0.1' && parts[0] !== '::1')) {
      throw new Error('Hostname already points elsewhere');
    }
    if (entries.some(parts => parts[0] === '127.0.0.1')) continue;
    if (!result.endsWith('\n')) result += '\n';
    result += `127.0.0.1 ${name} # LeftOpen fixed address\n`;
  }
  return result;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.getuid() !== 0) throw new Error('Administrator authorization required');
  const original = fs.readFileSync('/etc/hosts', 'utf8');
  const updated = addingHosts(original, process.argv.slice(2));
  if (updated !== original) {
    const metadata = fs.statSync('/etc/hosts');
    const temporary = `/etc/.leftopen-hosts-${crypto.randomUUID()}`;
    try {
      fs.writeFileSync(temporary, updated, { mode: metadata.mode & 0o777, flag: 'wx' });
      fs.chownSync(temporary, metadata.uid, metadata.gid);
      if (fs.readFileSync('/etc/hosts', 'utf8') !== original) throw new Error('Hosts file changed; try again');
      fs.renameSync(temporary, '/etc/hosts');
    } finally { try { fs.unlinkSync(temporary); } catch {} }
  }
  if (fs.readFileSync('/etc/hosts', 'utf8') !== updated) throw new Error('DNS update verification failed');
}
