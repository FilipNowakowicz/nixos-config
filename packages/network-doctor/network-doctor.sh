# shellcheck shell=bash
if [[ $# != 1 || ($1 != main && $1 != worker) ]]; then
  echo "Usage: network-doctor {main|worker}" >&2
  exit 2
fi

failed=0
probe() {
  local label=$1 status
  shift
  printf '\n[%s]\n' "$label"
  if timeout -k 1 8 "$@"; then
    return
  else
    status=$?
    printf 'Probe failed (exit %d)\n' "$status" >&2
    failed=1
  fi
}

read -r uptime_seconds _ </proc/uptime
printf 'mode=%s time=%s boot_id=%s uptime_seconds=%s\n' \
  "$1" "$(date -u +%FT%TZ)" "$(</proc/sys/kernel/random/boot_id)" "$uptime_seconds"

if [[ $1 == main ]]; then
  probe 'NetworkManager links' nmcli -t -f DEVICE,TYPE,STATE device status
  probe 'Mullvad tunnel' mullvad status
  probe 'Lockdown setting' mullvad lockdown-mode get
  probe 'Tailscale backend state' bash -o pipefail -c 'tailscale status --json --peers=false | jq -er .BackendState'
  probe 'IPv4 policy rules' ip -4 rule
  probe 'IPv6 policy rules' ip -6 rule
  probe 'resolved DNS scopes' resolvectl status
  probe 'MagicDNS lookup' resolvectl query --cache=no "${MAGICDNS_NAME}."
else
  probe 'System resolver configuration' cat /etc/resolv.conf
fi

probe 'IPv4 DNS proxy route' ip route get 100.100.100.100
probe 'IPv6 DNS proxy route' ip -6 route get fd7a:115c:a1e0::53
probe 'AdGuard route' ip route get "$ADGUARD_ADDRESS"
probe 'AdGuard UDP' host -U -W 2 -R 1 -t A pypi.org. "$ADGUARD_ADDRESS"
probe 'AdGuard TCP' host -T -W 2 -R 1 -t A pypi.org. "$ADGUARD_ADDRESS"
if [[ $1 == main ]]; then
  probe 'Public lookup and answering link' resolvectl query --cache=no pypi.org.
else
  probe 'Package index system lookup' getent ahosts pypi.org
  probe 'Package index HTTPS' curl -fsSIL --max-time 7 -o /dev/null -w 'HTTP %{http_code}\n' https://pypi.org/simple/
fi
exit "$failed"
