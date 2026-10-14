#!/usr/bin/env python3
"""Display titles stay separate from package IDs and survive index generation."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
TITLES = {
    "ask_user": "Ask User",
    "claude-code": "Claude Code",
    "codex": "Codex",
    "cron": "Cron",
    "fork": "Fork",
    "git-diff": "Git Diff",
    "history": "History",
    "mcp": "MCP",
    "md": "Markdown",
    "prompt-suggestions": "Prompt Suggestions",
    "recap": "Recap",
    "review": "Review",
    "shell": "Shell",
    "skill": "Skills",
    "subagent": "Subagents",
    "themes": "Themes",
    "todo": "Todo",
    "usage": "Usage",
    "web_search": "Web Search",
    "windows": "Windows",
}


class CatalogTitlesTest(unittest.TestCase):
    def test_package_display_titles(self):
        packages = {p.name for p in (ROOT / "plugins").iterdir() if p.is_dir()}
        self.assertEqual(packages, set(TITLES))
        catalog = {entry["name"]: entry for entry in json.loads((ROOT / "catalog.json").read_text()) if entry["kind"] == "plugin"}
        self.assertEqual(set(catalog), packages)
        for name, title in TITLES.items():
            with self.subTest(package=name):
                package = ROOT / "plugins" / name
                manifest = json.loads((package / "manifest.json").read_text())
                self.assertEqual(manifest["title"], title)
                self.assertEqual(catalog[name]["title"], title)
                self.assertEqual((package / "README.md").read_text().splitlines()[0], "# " + title)

    def test_generator_preserves_titles_ids_and_hashes(self):
        spec = importlib.util.spec_from_file_location("gen_index", ROOT / "gen-index.py")
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugins = root / "plugins"
            for name, manifest in [("internal_id", {"title": "Display Title"}), ("untitled-id", {})]:
                package = plugins / name
                package.mkdir(parents=True)
                (package / "manifest.json").write_text(json.dumps(manifest))
            with patch.object(generator, "ROOT", root), patch.object(generator, "KINDS", {"plugin": plugins}):
                with patch("sys.argv", ["gen-index.py"]):
                    generator.main()
                with patch("sys.argv", ["gen-index.py", "--check"]):
                    generator.main()
            entries = json.loads((root / "catalog.json").read_text())
            self.assertEqual([(e["name"], e["title"]) for e in entries],
                             [("internal_id", "Display Title"), ("untitled-id", "untitled-id")])
            for entry in entries:
                manifest_path = plugins / entry["name"] / "manifest.json"
                self.assertEqual(entry["files"], [{"path": "manifest.json", "sha256":
                    hashlib.sha256(manifest_path.read_bytes()).hexdigest()}])


if __name__ == "__main__":
    unittest.main()
