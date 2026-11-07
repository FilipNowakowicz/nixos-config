#!/usr/bin/env bash
# Regression from .agents/learning/candidates/archive/2026-11-07-quiet-shell-restart-test-session-scope.yml
set -euo pipefail
python3 tests/quiet-shell/test_session_processes.py
