#!/usr/bin/env python3
"""Print wlsunset's location arguments from the system timezone.

Sunset only needs a rough position, and an IP lookup would report the VPN exit. The
timezone is offline, private, and follows the machine.
"""

import os
import pathlib
import re
import sys


def degrees(text):
    """Convert ISO 6709 +DDMM, +DDMMSS, +DDDMM or +DDDMMSS to decimal degrees."""
    sign = -1 if text[0] == "-" else 1
    digits = text[1:]
    width = 2 + len(digits) % 2
    value = int(digits[:width]) + int(digits[width:width + 2]) / 60
    if len(digits) > width + 2:
        value += int(digits[width + 2:]) / 3600
    return sign * round(value, 2)


zone = os.environ.get("QUIET_TIMEZONE") or os.path.realpath("/etc/localtime").partition("zoneinfo/")[2]
table = pathlib.Path(os.environ["QUIET_ZONE_TAB"])
for line in table.read_text().splitlines():
    fields = line.split("\t")
    if not line.startswith("#") and len(fields) >= 3 and fields[2] == zone:
        match = re.fullmatch(r"([+-]\d+)([+-]\d+)", fields[1])
        if match:
            print("-l", degrees(match.group(1)), "-L", degrees(match.group(2)))
            sys.exit(0)
sys.exit(f"no coordinates for timezone {zone!r}")
