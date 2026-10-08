// Never emit command arguments, output, paths, environment or certificate material.
export function commandDiagnostic(stage, result) {
  const event = {stage};
  if (Number.isInteger(result.status)) event.exitCode = result.status;
  if (/^SIG[A-Z0-9]{1,12}$/.test(result.signal ?? '')) event.signal = result.signal;
  if (/^E[A-Z0-9]{1,24}$/.test(result.error?.code ?? '')) event.errorCode = result.error.code;
  process.stderr.write('LEFTOPEN_DIAGNOSTIC:' + JSON.stringify(event) + '\n');
}
