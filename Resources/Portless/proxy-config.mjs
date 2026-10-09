export function proxyPort(value = '443') {
  if (typeof value !== 'string' || !/^[1-9][0-9]{0,4}$/.test(value)) throw new Error('invalidPort');
  const port = Number(value);
  if (port > 65535 || (port >= 1355 && port <= 1365)) throw new Error('invalidPort');
  return port;
}

export async function selectProxyPort(preferred, busy, owned) {
  for (const port of [...new Set([preferred, ...Array.from({length: 20}, (_, i) => 8443 + i)])]) {
    if (!(await busy(port))) return port;
    if (port === preferred && owned()) return port;
  }
  throw new Error('portBusy');
}
