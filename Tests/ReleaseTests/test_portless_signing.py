import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_runtime", ROOT / "Scripts/verify-portless-runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class PortlessSigningTests(unittest.TestCase):
    def test_permissions_are_architecture_scoped(self):
        def permissions(name):
            return plistlib.loads((ROOT / "Resources/Portless" / name).read_bytes())
        arm = {"com.apple.security.cs.allow-jit": True}
        self.assertEqual(permissions("node-entitlements.plist"), arm)
        self.assertEqual(permissions("node-x64-entitlements.plist"), {
            **arm, "com.apple.security.cs.allow-unsigned-executable-memory": True,
        })

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "runtime-lock.json").write_text(json.dumps({
            "nodeVersion": "24.14.0", "portlessVersion": "0.15.7",
        }))

    def result(self, output, code=0):
        return subprocess.CompletedProcess([], code, stdout=output, stderr="test failure")

    def test_executes_javascript_and_cli_without_inherited_node_options(self):
        with patch.dict(os.environ, {"NODE_OPTIONS": "--jitless"}), \
                patch.object(runtime.subprocess, "run", side_effect=[
                    self.result("v24.14.0 x64\n"), self.result("0.15.7\n"),
                ]) as run:
            runtime.verify(self.root, "x64")
        self.assertEqual(run.call_count, 2)
        javascript, cli = run.call_args_list
        self.assertEqual(javascript.args[0][1], "-e")
        self.assertIn("new Function", javascript.args[0][2])
        self.assertNotIn("NODE_OPTIONS", javascript.kwargs["env"])
        self.assertEqual(javascript.kwargs["timeout"], 30)
        self.assertEqual(cli.args[0][-1], "--version")

    def test_rejects_crashing_runtime(self):
        with patch.object(runtime.subprocess, "run", return_value=self.result("", -5)), \
                self.assertRaisesRegex(RuntimeError, "runtime failed"):
            runtime.verify(self.root, "x64")

    def test_rejects_wrong_architecture(self):
        with patch.object(runtime.subprocess, "run", return_value=self.result("v24.14.0 arm64")), \
                self.assertRaisesRegex(RuntimeError, "Runtime mismatch"):
            runtime.verify(self.root, "x64")

    def test_rejects_wrong_portless(self):
        with patch.object(runtime.subprocess, "run", side_effect=[
                self.result("v24.14.0 x64"), self.result("0.0.0")]), \
                self.assertRaisesRegex(RuntimeError, "Portless version mismatch"):
            runtime.verify(self.root, "x64")

    def test_rejects_timeout(self):
        with patch.object(runtime.subprocess, "run", side_effect=subprocess.TimeoutExpired("node", 30)), \
                self.assertRaises(subprocess.TimeoutExpired):
            runtime.verify(self.root, "x64")
