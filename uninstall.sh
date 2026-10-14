#!/usr/bin/env bash
# Remove restic-backup-kit's scripts and systemd timers.
# Your config, password and the backup repository itself are KEPT unless you pass --purge-config.
# The repository (your actual backups) is never deleted by this script.
#
#   sudo ./uninstall.sh                 remove scripts and timers, keep /etc/restic-backup-kit
#   sudo ./uninstall.sh --purge-config  also delete /etc/restic-backup-kit (config + password!)

set -Eeuo pipefail

BIN_DIR=/usr/local/bin
CONF_DIR=/etc/restic-backup-kit
UNIT_DIR=/etc/systemd/system
UNITS=(restic-backup.timer restic-restore-test.timer restic-backup.service restic-restore-test.service)
PURGE=0
[[ ${1:-} == --purge-config ]] && PURGE=1

[[ $(id -u) -eq 0 ]] || { echo "run as root (sudo ./uninstall.sh)" >&2; exit 1; }

if [[ -d /run/systemd/system ]]; then
  systemctl disable --now restic-backup.timer restic-restore-test.timer 2>/dev/null || true
fi
for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; done
[[ -d /run/systemd/system ]] && systemctl daemon-reload
rm -f "$BIN_DIR/restic-backup" "$BIN_DIR/restic-restore-test"
echo "removed scripts and systemd units"

if ((PURGE)); then
  if [[ -t 0 ]]; then
    echo "This deletes $CONF_DIR including the repository PASSWORD."
    echo "Without the password your existing backups can never be restored."
    read -r -p "Type 'delete' to continue: " answer
    [[ $answer == delete ]] || { echo "kept $CONF_DIR"; exit 0; }
  fi
  rm -rf "$CONF_DIR"
  echo "deleted $CONF_DIR"
else
  echo "kept $CONF_DIR (config and password). Your backup repository was not touched."
fi
