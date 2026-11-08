#!/usr/bin/env python3
"""Fail closed on missing license metadata and never recursively upload exclusions."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.error import HTTPError
from urllib.request import urlopen


def query(*args):
    return json.loads(subprocess.check_output(args, text=True))


def license_status(meta):
    licenses = meta.get("license", [])
    if isinstance(licenses, dict):
        licenses = [licenses]
    if not isinstance(licenses, list) or not licenses:
        return "unknown"
    if any(isinstance(item, dict) and item.get("free") is False for item in licenses):
        return "unfree"
    if all(isinstance(item, dict) and item.get("free") is True for item in licenses):
        return "free"
    return "unknown"


def select_paths(graph, metadata, upstream):
    """Require every transitive reference to be audited free or already upstream."""
    eligible = {
        path for path in graph
        if metadata.get(path, "unknown") == "free"
        or (path in upstream and metadata.get(path) != "unfree")
    }
    while True:
        narrowed = {
            path for path in eligible
            if set(graph[path]["references"]) <= eligible
        }
        if narrowed == eligible:
            return eligible - upstream
        eligible = narrowed


def main():
    roots = Path(os.environ["PATHS_FILE"]).read_text().splitlines()
    if not roots:
        print("No paths to publish.")
        return
    if any(not path.startswith("/nix/store/") or "/" in path[11:] for path in roots):
        raise ValueError("Expected absolute store roots in PATHS_FILE")
    # Query complete realized closures, rather than just the validation roots.
    graph = query("nix", "path-info", "--json", "--recursive", *roots)
    if isinstance(graph, list):
        graph = {item["path"]: item for item in graph}
    # License metadata is evaluation data, not retained in .drv files. Only
    # exact output paths from the pinned package set count as positive evidence.
    packages = query(
        "nix-env", "-f", os.environ["CACHE_NIXPKGS_SOURCE"],
        "--arg", "config", "{ allowUnfree = true; allowBroken = true; }",
        "--query", "--available", "--json", "--meta", "--out-path",
    )
    metadata = {}
    for package in packages.values():
        status = license_status(package.get("meta", {}))
        for path in package.get("outputs", {}).values():
            # Conflicting metadata is rejected, even if one alias says free.
            previous = metadata.get(path, status)
            metadata[path] = status if status == previous else "unfree"
    # Only an explicit HTTP 404 counts as absence; transport/server errors abort.
    def upstream_present(path):
        store_hash = Path(path).name.split("-", 1)[0]
        try:
            with urlopen(f"https://cache.nixos.org/{store_hash}.narinfo", timeout=30) as response:
                fields = dict(line.split(": ", 1) for line in response.read().decode().splitlines() if ": " in line)
                if fields.get("StorePath") != path:
                    raise ValueError("Upstream narinfo store path mismatch")
                return path
        except HTTPError as error:
            if error.code == 404:
                return None
            raise

    with ThreadPoolExecutor(max_workers=16) as pool:
        upstream = {path for path in pool.map(upstream_present, sorted(graph)) if path}
    selected = select_paths(graph, metadata, upstream)
    for path in sorted(set(graph) - upstream - selected):
        print(f"Withholding {path}: unknown/unfree metadata or excluded reference")
    print(f"Publishing {len(selected)} paths; {len(upstream)} already in cache.nixos.org")
    # CLI uploads exactly one NAR at a time. nix copy would recursively re-add
    # references and defeat the upstream subtraction and licensing policy.
    with tempfile.TemporaryDirectory(prefix="cloudsmith-nar-") as directory:
        for path in sorted(selected):
            info = graph[path]
            store_hash = Path(path).name.split("-", 1)[0]
            nar = Path(directory) / f"{store_hash}.nar"
            narinfo = nar.with_suffix(".narinfo")
            with nar.open("wb") as output:
                subprocess.run(["nix-store", "--dump", path], stdout=output, check=True)
            nar_hash = "sha256:" + subprocess.check_output([
                "nix", "hash", "convert", "--hash-algo", "sha256", "--to", "nix32", info["narHash"],
            ], text=True).strip()
            narinfo.write_text(
                f"StorePath: {path}\nURL: {nar.name}\nCompression: none\n"
                f"FileHash: {nar_hash}\nFileSize: {info['narSize']}\n"
                f"NarHash: {nar_hash}\nNarSize: {info['narSize']}\n"
                "References: " + " ".join(Path(ref).name for ref in info["references"]) + "\n"
            )
            subprocess.run([
                "uvx", "--from", "cloudsmith-cli==1.30.0", "cloudsmith",
                "push", "nix", "nixos/nix-cache", str(nar),
                "--narinfo-file", str(narinfo),
            ], check=True)
            nar.unlink()
            narinfo.unlink()


if __name__ == "__main__":
    main()
