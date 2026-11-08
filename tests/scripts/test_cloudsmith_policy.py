"""Offline publication policy fixtures: no credentials, Nix builds, or uploads."""
import importlib.util
import contextlib
import io
import os
import tempfile
from unittest.mock import patch
from urllib.error import HTTPError
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

    def test_uploader_subprocess_boundary_never_exports_exclusions(self):
        base = "/nix/store/" + "0" * 32 + "-base"
        dep = "/nix/store/" + "1" * 32 + "-dependency"
        root = "/nix/store/" + "2" * 32 + "-root"
        discord = "/nix/store/" + "3" * 32 + "-discord"
        badroot = "/nix/store/" + "4" * 32 + "-badroot"
        graph = {
            path: {"references": refs, "narHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "narSize": 7}
            for path, refs in ((base, []), (dep, [base]), (root, [dep]), (discord, []), (badroot, [discord]))
        }
        packages = {
            path: {"meta": {"license": {"free": path != discord}}, "outputs": {"out": path}}
            for path in graph
        }
        dumped, uploaded, narinfos = [], [], []

        def fake_query(*args):
            return graph if args[0] == "nix" else packages

        def fake_urlopen(url, timeout):
            if "0" * 32 in url:
                return io.BytesIO(f"StorePath: {base}\n".encode())
            raise HTTPError(url, 404, "absent", {}, None)

        def fake_run(args, **kwargs):
            if args[0] == "nix-store":
                dumped.append(args[-1])
                kwargs["stdout"].write(b"fixture")
            else:
                uploaded.append(args)
                narinfos.append(Path(args[-1]).read_text())

        with tempfile.TemporaryDirectory() as directory:
            roots_file = Path(directory) / "roots"
            roots_file.write_text(root + "\n" + badroot + "\n")
            with patch.dict(os.environ, {"PATHS_FILE": str(roots_file), "CACHE_NIXPKGS_SOURCE": "/pinned", "CLOUDSMITH_API_KEY": "test-secret"}), patch.object(uploader, "query", fake_query), patch.object(uploader, "urlopen", fake_urlopen), patch.object(uploader.subprocess, "run", fake_run), patch.object(uploader.subprocess, "check_output", return_value="0" * 52), contextlib.redirect_stdout(io.StringIO()) as output:
                uploader.main()
        self.assertEqual(set(dumped), {root, dep})
        self.assertEqual(len(uploaded), 2)
        self.assertTrue(all(args[:6] == ["uvx", "--from", "cloudsmith-cli==1.30.0", "cloudsmith", "push", "nix"] for args in uploaded))
        self.assertNotIn("test-secret", repr(uploaded) + output.getvalue())
        self.assertTrue(all("NarHash: sha256:" + "0" * 52 in text for text in narinfos))
        self.assertTrue(any("References: " + Path(base).name in text for text in narinfos))

    def test_license_metadata_must_be_explicit_and_all_free(self):
        self.assertEqual(uploader.license_status({}), "unknown")
        self.assertEqual(uploader.license_status({"license": "MIT"}), "unknown")
        self.assertEqual(uploader.license_status({"license": {"free": True}}), "free")
        self.assertEqual(uploader.license_status({"license": [{"free": True}, {"free": False}]}), "unfree")


if __name__ == "__main__":
    unittest.main()
