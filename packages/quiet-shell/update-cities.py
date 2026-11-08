#!/usr/bin/env python3
"""Refresh shell/data/cities.tsv.gz, the towns Spotlight's "location" search offers.

Usage: python3 update-cities.py. Downloads GeoNames' list of places with at least
15,000 people (CC BY 4.0, https://www.geonames.org) and keeps what the shell needs:
name, plain-letter name, country code, region, population, latitude, longitude and
time zone, one place per line. Rarely worth rerunning; towns don't move.
"""

import gzip
import io
import pathlib
import urllib.request
import zipfile

BASE = "https://download.geonames.org/export/dump/"
out = pathlib.Path(__file__).parent / "shell/data/cities.tsv.gz"


def fetch(name):
    with urllib.request.urlopen(BASE + name, timeout=60) as response:
        return response.read()


regions = {}
for line in fetch("admin1CodesASCII.txt").decode().splitlines():
    fields = line.split("\t")
    regions[fields[0]] = fields[1]

with zipfile.ZipFile(io.BytesIO(fetch("cities15000.zip"))) as archive:
    text = archive.read("cities15000.txt").decode()

rows = []
for line in text.splitlines():
    f = line.split("\t")
    ascii_name = f[2] if f[2] != f[1] else ""
    region = regions.get(f"{f[8]}.{f[10]}", "")
    rows.append("\t".join([f[1], ascii_name, f[8], region, f[14], f"{float(f[4]):.2f}", f"{float(f[5]):.2f}", f[17]]))
rows.sort(key=lambda row: -int(row.split("\t")[4] or 0))

# A fixed timestamp, so the same data gives the same file.
with gzip.GzipFile(out, "wb", compresslevel=9, mtime=0) as packed:
    packed.write(("\n".join(rows) + "\n").encode())
print(f"{len(rows)} places written to {out}")
