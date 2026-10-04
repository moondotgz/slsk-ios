import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_icon import main


class IconTests(unittest.TestCase):
    def test_generates_all_iphone_ipad_and_marketing_entries(self):
        previous_directory = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                Path("assets").mkdir()
                Path("assets/icon.png").write_bytes(b"test-icon")

                def resize(command, check):
                    self.assertTrue(check)
                    self.assertEqual(command[0], "sips")
                    Path(command[-1]).write_bytes(b"resized-icon")

                with patch("prepare_icon.subprocess.run", side_effect=resize):
                    main()
                destination = Path("App/Assets.xcassets/AppIcon.appiconset")
                entries = json.loads((destination / "Contents.json").read_text())["images"]
                self.assertEqual(len(entries), 18)
                self.assertEqual({entry["idiom"] for entry in entries}, {"iphone", "ipad", "ios-marketing"})
                self.assertTrue(all((destination / entry["filename"]).is_file() for entry in entries))
                self.assertTrue((destination / "icon-1024.png").is_file())
            finally:
                os.chdir(previous_directory)


if __name__ == "__main__":
    unittest.main()
