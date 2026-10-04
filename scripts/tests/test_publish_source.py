import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from publish_source import generate


class SourceTests(unittest.TestCase):
    def test_catalog_matches_packaged_app_and_immutable_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "Slsk-unsigned.ipa"
            metadata = {"CFBundleIdentifier": "app.slsk.ios", "CFBundleShortVersionString": "1.0.123",
                        "CFBundleVersion": "123", "MinimumOSVersion": "16.0"}
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr("Payload/Slsk.app/Info.plist", plistlib.dumps(metadata))
                archive.writestr("Payload/Slsk.app/PlugIns/Test.appex/Info.plist", plistlib.dumps({}))
            icon = root / "icon.png"
            icon.write_bytes(b"test-icon")
            output = root / "site"
            source = generate(ipa, icon, "moondotgz/slsk-ios", "build-123-1",
                              "https://moondotgz.github.io/slsk-ios/", output)
            self.assertEqual(json.loads((output / "source.json").read_text()), source)
            app = source["apps"][0]
            version = app["versions"][0]
            self.assertEqual(app["bundleIdentifier"], metadata["CFBundleIdentifier"])
            self.assertEqual(version["version"], "1.0.123")
            self.assertEqual(version["buildVersion"], "123")
            self.assertEqual(version["minOSVersion"], "16.0")
            self.assertEqual(version["size"], ipa.stat().st_size)
            self.assertEqual(version["sha256"], hashlib.sha256(ipa.read_bytes()).hexdigest())
            self.assertEqual(version["downloadURL"],
                             "https://github.com/moondotgz/slsk-ios/releases/download/build-123-1/Slsk-unsigned.ipa")
            self.assertEqual(app["downloadURL"], version["downloadURL"])
            self.assertEqual(source["sourceURL"], "https://moondotgz.github.io/slsk-ios/source.json")
            self.assertEqual(app["iconURL"], "https://moondotgz.github.io/slsk-ios/icon.png")
            self.assertEqual((output / "icon.png").read_bytes(), icon.read_bytes())
            self.assertTrue((output / "index.html").is_file())

    def test_rejects_ambiguous_or_empty_ipa(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "app.ipa"
            for count in [0, 2]:
                with zipfile.ZipFile(ipa, "w") as archive:
                    for index in range(count):
                        archive.writestr(f"Payload/App{index}.app/Info.plist", plistlib.dumps({}))
                with self.assertRaises(ValueError):
                    generate(ipa, root / "icon.png", "owner/repo", "test", "https://example.com", root / "site")


if __name__ == "__main__":
    unittest.main()
