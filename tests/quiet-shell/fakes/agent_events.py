#!/usr/bin/env python3
"""Stand-in for `agent-desktop events --follow`: prints the lines a test appends.

Lines come from $QUIET_AGENT_EVENTS_FILE, one JSON event each. The commands inside
the events are other fakes, so tests see them run in the fake state's log.
"""

import json
import os
import pathlib
import sys
import time

if sys.argv[1:] == ["events", "--follow"]:
    path = pathlib.Path(os.environ["QUIET_AGENT_EVENTS_FILE"])
    path.touch()
    with path.open() as stream:
        while True:
            line = stream.readline()
            if line:
                print(line.strip(), flush=True)
            else:
                time.sleep(0.1)
