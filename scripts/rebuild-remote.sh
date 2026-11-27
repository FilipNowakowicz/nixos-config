#!/usr/bin/env bash
# shellcheck disable=SC2154
# Switch `main` to this checkout with every build step on gcp-builder. The system
# is still evaluated here, and the finished closure is copied back to activate it.
set -euo pipefail

CDPATH='' cd -- "$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/lib/builder.sh disable=SC1091
source scripts/lib/builder.sh

spec=$(builder_spec)
BUILDER_QUOTA_WAIT=${BUILDER_QUOTA_WAIT:-1800} start_builder

exec nh os switch --hostname "$(hostname)" . "$@" -- --max-jobs 0 --builders "$spec"
