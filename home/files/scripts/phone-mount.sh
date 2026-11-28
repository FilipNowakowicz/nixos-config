# shellcheck shell=bash
# Mount a phone's shared storage over KDE Connect and wait until it can be read.
#
# usage: phone-mount DEVICE_ID
#
# MOUNTS, FUSERMOUNT and PHONE_MOUNT_TRIES exist for the tests.
device=$1
mount=$XDG_RUNTIME_DIR/$device
root=$mount/storage/emulated/0
# Only NixOS's setuid wrapper may unmount as a user.
fusermount=${FUSERMOUNT:-/run/wrappers/bin/fusermount3}
sftp=(busctl --user --timeout=90 call org.kde.kdeconnect
  "/modules/kdeconnect/devices/$device/sftp" org.kde.kdeconnect.device.sftp)

# A dropped connection can leave the mount registered with nothing answering
# behind it, and sshfs cannot mount over that. The mount table is read directly,
# because touching a hung mount can block.
if grep -qF " $mount " "${MOUNTS:-/proc/self/mounts}" &&
  ! timeout --signal=KILL 10 stat "$mount" >/dev/null 2>&1; then
  echo "phone-backup: clearing a dead mount at $mount" >&2
  # Make KDE Connect forget the mount, then detach it in case it could not.
  "${sftp[@]}" unmount >/dev/null || true
  "$fusermount" -uz "$mount" 2>/dev/null || true
fi

if [[ $("${sftp[@]}" mountAndWait) != "b true" ]]; then
  echo "phone-backup: mounting the phone failed: $("${sftp[@]}" getMountError)" >&2
  exit 1
fi

# mountAndWait returns as soon as sshfs has started, which can be before the
# filesystem is there.
for ((try = 0; try < ${PHONE_MOUNT_TRIES:-30}; try++)); do
  if timeout --signal=KILL 10 test -d "$root/DCIM"; then
    exit 0
  fi
  sleep 1
done

echo "phone-backup: no shared storage at $root; last mount error: $("${sftp[@]}" getMountError)" >&2
exit 1
