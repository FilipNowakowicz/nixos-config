# The phone backup's mount step waits for a slow sshfs, clears a dead mount
# first, and leaves a working one alone.
{
  nixpkgs,
  system,
  ...
}:
let
  pkgs = nixpkgs.legacyPackages.${system};

  # KDE Connect: mountAndWait returns before the storage exists, as the real one
  # does. APPEARS_AFTER is the delay in seconds, or "never".
  busctl = pkgs.writeShellScriptBin "busctl" ''
    method=''${!#}
    echo "$method" >>"$STATE/calls"
    case $method in
      mountAndWait)
        echo "b ''${MOUNT_RESULT:-true}"
        if [[ ''${APPEARS_AFTER:-0} != never ]]; then
          (sleep "''${APPEARS_AFTER:-0}"; mkdir -p "$STORAGE/DCIM") >/dev/null 2>&1 &
        fi
        ;;
      getMountError) echo 's "sshfs finished with exit code 1"' ;;
    esac
  '';
  # A dead mount fails stat until it has been detached.
  stat = pkgs.writeShellScriptBin "stat" ''
    [[ ! -e $STATE/dead ]]
  '';
  fusermount = pkgs.writeShellScript "fusermount3" ''
    echo "fusermount $1" >>"$STATE/calls"
    rm -f "$STATE/dead"
  '';

  phoneMount = pkgs.writeShellApplication {
    name = "phone-mount";
    # The stubs come first, so `stat` is not coreutils'.
    runtimeInputs = [
      busctl
      stat
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = builtins.readFile ../../home/files/scripts/phone-mount.sh;
  };
in
pkgs.runCommand "phone-mount-tests" { } ''
  set -euo pipefail

  setup() { # $1=case name
    export XDG_RUNTIME_DIR=$PWD/$1 STATE=$PWD/$1/state
    export STORAGE=$XDG_RUNTIME_DIR/phone/storage/emulated/0
    export MOUNTS=$STATE/mounts FUSERMOUNT=${fusermount}
    mkdir -p "$STATE"
    : >"$MOUNTS"
    : >"$STATE/calls"
  }
  registered() { echo "user@phone:/ $XDG_RUNTIME_DIR/phone fuse.sshfs rw 0 0" >"$MOUNTS"; }
  run() { ${pkgs.lib.getExe phoneMount} phone 2>"$STATE/err"; }
  calls() { tr '\n' ' ' <"$STATE/calls"; }
  expect_calls() {
    [[ $(calls) == "$1" ]] || { echo "want calls '$1', got '$(calls)'" >&2; exit 1; }
  }

  # Storage that appears after mountAndWait has returned is waited for.
  setup slow
  APPEARS_AFTER=2 run
  expect_calls "mountAndWait "

  # A dead mount is cleared before mounting.
  setup dead
  registered
  touch "$STATE/dead"
  run
  expect_calls "unmount fusermount -uz mountAndWait "

  # A working mount is left alone.
  setup healthy
  registered
  run
  expect_calls "mountAndWait "

  # Storage that never appears fails with KDE Connect's error.
  setup never
  ! APPEARS_AFTER=never PHONE_MOUNT_TRIES=2 run
  grep -q 'no shared storage.*sshfs finished with exit code 1' "$STATE/err"

  # So does a mount KDE Connect reports as failed.
  setup refused
  ! MOUNT_RESULT=false APPEARS_AFTER=never run
  grep -q 'mounting the phone failed' "$STATE/err"

  touch $out
''
