#!/usr/bin/env python3
"""Parse tests/mutation/mutants.txt and apply or list mutants.

Usage:
  apply.py list                  print "<id>\t<area>\t<layer>\t<expected>\t<summary>"
  apply.py apply <id> [root]     apply the edits of one mutant under root (default .)
  apply.py files <id>            print the files a mutant touches

Each old text must occur exactly once in its file, otherwise apply exits 2 and
leaves every file untouched.
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent


def parse(path=HERE / "mutants.txt"):
    mutants = []
    cur = None
    mode = None
    buf_old, buf_new = [], []
    edit = None
    for raw in path.read_text().split("\n"):
        if mode is None:
            if raw.startswith("## "):
                fields = [f.strip() for f in raw[3:].split("|")]
                cur = {"id": fields[0], "area": fields[1], "layer": fields[2],
                       "expected": fields[3], "summary": "", "edits": []}
                mutants.append(cur)
            elif raw.startswith("@@ ") and cur is not None:
                edit = {"file": raw[3:].strip()}
            elif raw == "<<<<" and edit is not None:
                mode, buf_old = "old", []
            elif cur is not None and edit is None and raw.strip() and not raw.startswith("#"):
                cur["summary"] = raw.strip()
        elif mode == "old":
            if raw == "====":
                mode, buf_new = "new", []
            else:
                buf_old.append(raw)
        elif mode == "new":
            if raw == ">>>>":
                edit["old"] = "\n".join(buf_old) + "\n"
                edit["new"] = ("\n".join(buf_new) + "\n") if buf_new else ""
                if edit["old"] == "*\n":
                    edit["old"] = "*"
                cur["edits"].append(edit)
                mode, edit = None, None
            else:
                buf_new.append(raw)
    return mutants


def apply(mutant, root):
    staged = {}
    for e in mutant["edits"]:
        p = root / e["file"]
        text = staged.get(p, p.read_text())
        if e["old"] == "*":
            staged[p] = e["new"]
            continue
        n = text.count(e["old"])
        if n != 1:
            sys.exit(f"{mutant['id']}: old text occurs {n} times in {e['file']}")
        staged[p] = text.replace(e["old"], e["new"])
    for p, text in staged.items():
        p.write_text(text)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    ms = parse()
    if argv[1] == "list":
        for m in ms:
            print("\t".join([m["id"], m["area"], m["layer"], m["expected"], m["summary"]]))
        return
    by_id = {m["id"]: m for m in ms}
    m = by_id.get(argv[2]) if len(argv) > 2 else None
    if m is None:
        sys.exit("unknown mutant id")
    if argv[1] == "files":
        print("\n".join(sorted({e["file"] for e in m["edits"]})))
    elif argv[1] == "apply":
        apply(m, pathlib.Path(argv[3] if len(argv) > 3 else "."))
    else:
        sys.exit(__doc__)


main(sys.argv)
