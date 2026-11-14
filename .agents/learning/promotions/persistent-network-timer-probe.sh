#!/usr/bin/env bash
# Regression from .agents/learning/candidates/archive/2026-11-14-main-network-units-need-repo-probe.yml
set -euo pipefail
nix build --no-link \
  .#checks.x86_64-linux.lib-invariants \
  .#checks.x86_64-linux.invariants-main \
  .#checks.x86_64-linux.invariants-main-ci
