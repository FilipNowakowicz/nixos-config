#!/usr/bin/env bash
# Runs on the target over SSH. Retry startup races, fail visibly after exhaustion.
set -euo pipefail
export PATH="/run/current-system/sw/bin:$PATH"
for attempt in {1..10}; do
  failed_units=$(systemctl --failed --no-legend --plain --no-pager)
  if [[ -z $failed_units ]] &&
    curl --fail --silent --show-error --max-time 10 http://127.0.0.1:9090/-/ready >/dev/null &&
    curl --fail --silent --show-error --max-time 10 http://127.0.0.1:3100/ready >/dev/null &&
    curl --fail --silent --show-error --max-time 10 http://127.0.0.1:3000/grafana/api/health | jq -e '.database == "ok"' >/dev/null &&
    dig +time=5 +tries=1 @127.0.0.1 example.com A | grep -q 'status: NOERROR' &&
    dig +tcp +time=5 +tries=1 @127.0.0.1 example.com A | grep -q 'status: NOERROR'; then
    echo 'Homeserver failed-unit, Prometheus, Loki, Grafana and AdGuard DNS checks passed.'
    exit 0
  fi
  printf 'Health checks failed (attempt %s/10); failed units:\n%s\n' "$attempt" "$failed_units" >&2
  [[ $attempt == 10 ]] || sleep 5
done
exit 1
