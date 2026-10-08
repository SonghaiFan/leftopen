export function proxyPort(value = '443') {
  if (typeof value !== 'string' || !/^[1-9][0-9]{0,4}$/.test(value)) throw new Error('invalidPort');
  const port = Number(value);
  if (port > 65535 || (port >= 1355 && port <= 1365)) throw new Error('invalidPort');
  return port;
}
