#!/usr/bin/env python3
"""Exercise signed Node/V8 and Portless without installing or trusting anything."""
import argparse
import json
import platform
import subprocess
import tempfile
from pathlib import Path


def verify(runtime, architecture):
    runtime = Path(runtime).resolve()
    lock = json.loads((runtime / "runtime-lock.json").read_text())
    node = runtime / f"node-{architecture}"
    # --version alone never creates a V8 isolate and missed the Intel crash.
    javascript = """
const crypto = require('node:crypto');
const run = new Function('x', 'return x * x + 1');
for (let i = 0; i < 100000; i++) {
  if (run(i) !== i * i + 1) throw new Error('JavaScript smoke test failed');
}
if (crypto.createHash('sha256').update('leftopen').digest('hex').length !== 64)
  throw new Error('Crypto smoke test failed');
console.log(process.version + ' ' + process.arch);
"""
    with tempfile.TemporaryDirectory(prefix="leftopen-runtime-smoke-") as directory:
        # Do not inherit NODE_OPTIONS (especially --jitless) or user project state.
        environment = {"PATH": "/usr/bin:/bin", "HOME": directory,
                       "TMPDIR": directory, "LANG": "en_US.UTF-8"}
        def run(arguments):
            result = subprocess.run([str(node), *arguments], cwd=directory,
                                    env=environment, capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                raise RuntimeError(f"{architecture} runtime failed ({result.returncode}): {result.stderr}")
            return result.stdout.strip()
        expected = f"v{lock['nodeVersion']} {architecture}"
        actual = run(["-e", javascript])
        if actual != expected:
            raise RuntimeError(f"Runtime mismatch: expected {expected}, got {actual}")
        actual = run([str(runtime / "package/dist/cli.js"), "--version"])
        if actual != lock["portlessVersion"]:
            raise RuntimeError(f"Portless version mismatch: {actual}")
    print(f"Verified signed runtime: {expected}; Portless {actual}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("--architecture", choices=["arm64", "x64"],
                        default="arm64" if platform.machine() == "arm64" else "x64")
    args = parser.parse_args()
    verify(args.runtime, args.architecture)
