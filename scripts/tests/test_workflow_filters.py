import fnmatch
from pathlib import Path
import re
import unittest


class WorkflowFilterTests(unittest.TestCase):
    def patterns(self, event):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/build.yml").read_text()
        block = re.search(rf"^  {event}:\n(.*?)(?=^  \w+:)", workflow, re.M | re.S)
        self.assertIsNotNone(block)
        return re.findall(r"^      - '([^']+)'$", block.group(1), re.M)

    def test_both_events_cover_every_build_input(self):
        for event in ["push", "pull_request"]:
            patterns = self.patterns(event)
            for path in ["App/PasswordKeychain.swift", "Sources/SoulseekCore/Configuration.swift",
                         "Sources/CZlib/include/shims.h", "Tests/SoulseekCoreTests/NewTests.swift",
                         "assets/icon.png", "scripts/prepare_icon.py", "scripts/tests/test_source.py",
                         "Package.swift", "Package.resolved", "project.yml", ".github/workflows/build.yml"]:
                self.assertTrue(any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns), (event, path))

    def test_docs_only_changes_do_not_build_and_manual_trigger_remains(self):
        for event in ["push", "pull_request"]:
            patterns = self.patterns(event)
            for path in ["README.md", "AGENTS.md", "LICENSE", "docs/PROTOCOL_AUDIT.md",
                         "docs/reference/nicotine-plus/slskmessages.py", ".github/ISSUE_TEMPLATE/bug.md"]:
                self.assertFalse(any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns), (event, path))
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/build.yml").read_text()
        self.assertIn("\n  workflow_dispatch:\n", workflow)


if __name__ == "__main__":
    unittest.main()
