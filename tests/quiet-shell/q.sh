#!/usr/bin/env bash
# Run a command inside the nested session started by nested.sh.
# Usage: q.sh RUNDIR COMMAND...   e.g. q.sh run qs ipc call shell controls
run=$1; shift
set -a; source <(sed 's/^\([A-Z_]*\)=\(.*\)$/\1="\2"/' "$run/env"); set +a
exec "$@"
