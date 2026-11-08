"""Offline publication policy fixtures: no credentials, Nix builds, or uploads."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "uploader", Path(__file__).parents[2] / "scripts/push-to-cloudsmith.py"
)
uploader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uploader)


class PublicationPolicy(unittest.TestCase):
    def test_complete_free_closure_subtracts_upstream(self):
        graph = {
            "root": {"references": ["dep"]},
            "dep": {"references": ["base"]},
            "base": {"references": []},
        }
        selected = uploader.select_paths(graph, {"root": "free", "dep": "free"}, {"base"})
        self.assertEqual(selected, {"root", "dep"})
        for path in selected:
            self.assertLessEqual(set(graph[path]["references"]), selected | {"base"})

    def test_unfree_and_unknown_poison_transitive_dependents(self):
        for excluded in ("nvidia", "discord", "unknown-generated"):
            with self.subTest(excluded=excluded):
                graph = {
                    "root": {"references": ["middle"]},
                    "middle": {"references": [excluded]},
                    excluded: {"references": []},
                    "independent": {"references": ["independent"]},
                }
                metadata = {"root": "free", "middle": "free", "independent": "free"}
                if excluded != "unknown-generated":
                    metadata[excluded] = "unfree"
                self.assertEqual(uploader.select_paths(graph, metadata, set()), {"independent"})

    def test_known_unfree_upstream_is_not_a_license_bypass(self):
        graph = {"root": {"references": ["discord"]}, "discord": {"references": []}}
        self.assertEqual(uploader.select_paths(graph, {"root": "free", "discord": "unfree"}, {"discord"}), set())

    def test_license_metadata_must_be_explicit_and_all_free(self):
        self.assertEqual(uploader.license_status({}), "unknown")
        self.assertEqual(uploader.license_status({"license": "MIT"}), "unknown")
        self.assertEqual(uploader.license_status({"license": {"free": True}}), "free")
        self.assertEqual(uploader.license_status({"license": [{"free": True}, {"free": False}]}), "unfree")


if __name__ == "__main__":
    unittest.main()
