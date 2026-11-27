# Pre-start probe for main's restic units. network-online.target is a no-op
# here: main force-disables both wait-online providers (see networking.nix), so
# it orders against nothing. Probe the B2 backend directly with a bounded retry
# instead, so both restic units wait for real connectivity. This matters most
# after a long suspend: Persistent=true fires the missed run the instant the
# machine resumes, before Wi-Fi/VPN/DNS are back, and a single failed attempt
# otherwise leaves the backup stale until the next daily slot.
#
# --no-cache: the probe only tests reachability, and `restic cat config`
# treats an unlocatable cache directory as fatal. restic-check-local has no
# User= (so no $HOME) and no CacheDirectory=, so without this flag the probe
# failed every attempt on a reachable repo.
#
# Only transient failures are retried. restic exits 10 when the repository
# does not exist and 12 on a wrong password. Neither resolves by waiting, so
# both fail at once with their own message. A missing repository is never
# initialized from here: an existing repo that has become unreadable must not
# be silently replaced by a fresh one, so creating it is an operator step
# (`restic init`). hosts/main/checks.nix (restic-wait-repo-behaviour) runs this
# script against a fake and a real restic.
{ pkgs }:
{
  unit,
  repositoryFile,
  restic ? pkgs.restic,
  attempts ? 30,
  interval ? 10,
}:
pkgs.writeShellScript "${unit}-wait-repo" ''
  err=
  for _ in $(${pkgs.coreutils}/bin/seq 1 ${toString attempts}); do
    err=$(${restic}/bin/restic cat config --no-cache \
      --repository-file=${repositoryFile} 2>&1 >/dev/null) && exit 0
    case $? in
      10)
        echo "${unit}: repository does not exist; create it deliberately with restic init: $err" >&2
        exit 1
        ;;
      12)
        echo "${unit}: wrong repository password: $err" >&2
        exit 1
        ;;
    esac
    ${pkgs.coreutils}/bin/sleep ${toString interval}
  done
  echo "${unit}: B2 repo unreachable after ${toString attempts} attempts; last error: $err" >&2
  exit 1
''
