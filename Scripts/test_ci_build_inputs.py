import importlib.util
from pathlib import Path
import tempfile
import os
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ci_inputs", Path(__file__).with_name("ci_build_inputs.py"))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class BuildInputCacheTests(unittest.TestCase):
    def test_only_identical_content_gets_its_original_timestamp(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / "input.swift"
            source.write_text("first")
            manifest = Path(root) / "cache.json"
            original = 1_700_000_000_000_000_000
            checkout = original + 100_000_000_000
            os.utime(source, ns=(original, original))
            with patch.object(ci, "inputs", return_value=[source]):
                ci.run("save", manifest)
                os.utime(source, ns=(checkout, checkout))
                ci.run("restore", manifest)
                self.assertEqual(source.stat().st_mtime_ns, original)
                source.write_text("other")  # Same length, different content.
                os.utime(source, ns=(checkout, checkout))
                ci.run("restore", manifest)
                self.assertEqual(source.stat().st_mtime_ns, checkout)

    def test_missing_or_corrupt_manifest_is_a_cold_build(self):
        with tempfile.TemporaryDirectory() as root:
            manifest = Path(root) / "cache.json"
            with patch.object(ci, "inputs", return_value=[]):
                ci.run("restore", manifest)
                manifest.write_text("not json")
                ci.run("restore", manifest)


if __name__ == "__main__":
    unittest.main()
