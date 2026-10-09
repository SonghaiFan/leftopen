"""macOS-only packaging regression tests; no installed apps or icon caches touched."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class LegacyIconTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix="leftopen-icon-tests-")
        cls.directory = pathlib.Path(cls.workspace.name)
        cls.tool = cls.directory / "icon-tool"
        subprocess.run(["swiftc", str(ROOT / "Scripts/legacy-app-icon.swift"), "-o", str(cls.tool)], check=True)
        cls.source = ROOT / "Resources/AppIcon.icns"

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=self.directory)
        self.addCleanup(self.temp.cleanup)
        self.app = pathlib.Path(self.temp.name) / "Test.app"
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir(parents=True)
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIconFile": "AppIcon"}))
        self.icon = self.resources / "AppIcon.icns"

    def invoke(self, *args, success=True):
        result = subprocess.run([str(self.tool), *map(str, args)], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_all_sizes_match_padding_only_transform(self):
        original = self.source.read_bytes()
        self.invoke("generate", self.source, self.icon)
        self.invoke("verify", self.source, self.app)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertIn("1024px", self.invoke("audit", self.icon).stdout)

    def test_original_full_bleed_package_is_rejected(self):
        shutil.copyfile(self.source, self.icon)
        self.invoke("verify", self.source, self.app, success=False)

    def test_existing_output_is_not_overwritten(self):
        shutil.copyfile(self.source, self.icon)
        before = self.icon.read_bytes()
        self.invoke("generate", self.source, self.icon, success=False)
        self.assertEqual(self.icon.read_bytes(), before)

    def test_double_padding_is_rejected(self):
        self.invoke("generate", self.source, self.icon)
        self.invoke("generate", self.icon, self.resources / "double.icns", success=False)

    def test_alternate_icon_selector_is_rejected(self):
        self.invoke("generate", self.source, self.icon)
        self.info.write_bytes(plistlib.dumps({"CFBundleIconFile": "AppIcon", "CFBundleIconName": "Other"}))
        self.invoke("verify", self.source, self.app, success=False)

    def test_missing_packaged_icon_is_rejected(self):
        self.invoke("verify", self.source, self.app, success=False)


if __name__ == "__main__":
    unittest.main()
