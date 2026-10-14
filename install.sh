#!/usr/bin/env bash
# Install restic-backup-kit: scripts, config template, generated password and systemd timers.
# Safe to re-run: existing config and password are never overwritten.
#
#   sudo ./install.sh            install, do not start the timers yet
#   sudo ./install.sh --enable   install and enable the daily backup + weekly restore test

set -Eeuo pipefail

BIN_DIR=/usr/local/bin
CONF_DIR=/etc/restic-backup-kit
UNIT_DIR=/etc/systemd/system
ENABLE=0
[[ ${1:-} == --enable ]] && ENABLE=1

cd "$(dirname "$0")"
[[ $(id -u) -eq 0 ]] || { echo "run as root (sudo ./install.sh)" >&2; exit 1; }

missing=()
for c in restic jq curl; do command -v "$c" >/dev/null || missing+=("$c"); done
if ((${#missing[@]})); then
  if command -v apt-get >/dev/null; then
    echo "installing: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
  else
    echo "please install: ${missing[*]}" >&2
    exit 1
  fi
fi

install -m 755 bin/restic-backup bin/restic-restore-test "$BIN_DIR/"
echo "installed scripts in $BIN_DIR"

install -d -m 700 "$CONF_DIR"
if [[ ! -f $CONF_DIR/backup.env ]]; then
  install -m 600 config/backup.env.example "$CONF_DIR/backup.env"
  echo "created $CONF_DIR/backup.env  <- edit RESTIC_REPOSITORY and BACKUP_PATHS"
else
  echo "kept existing $CONF_DIR/backup.env"
fi
[[ -f $CONF_DIR/excludes.txt ]] || install -m 644 config/excludes.txt "$CONF_DIR/excludes.txt"

if [[ ! -f $CONF_DIR/password ]]; then
  (umask 077 && head -c 32 /dev/urandom | base64 >"$CONF_DIR/password")
  echo ""
  echo "Generated a random repository password in $CONF_DIR/password"
  echo "SAVE A COPY OF IT OUTSIDE THIS SERVER (password manager). Without it the backups cannot be restored."
  echo ""
fi

install -d -m 700 /var/cache/restic
install -m 644 systemd/*.service systemd/*.timer "$UNIT_DIR/"
if [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  if ((ENABLE)); then
    systemctl enable --now restic-backup.timer restic-restore-test.timer
    echo "timers enabled:"
    systemctl list-timers 'restic-*' --no-pager || true
  fi
else
  echo "systemd is not running here; timers were installed but not enabled"
fi

cat <<EOF

Next steps:
  1. sudo nano $CONF_DIR/backup.env        # set RESTIC_REPOSITORY and BACKUP_PATHS
  2. sudo restic-backup --init             # first backup, creates the repository
  3. sudo restic-restore-test              # prove it restores
  4. sudo ./install.sh --enable             # daily backup at ~02:30, restore test on Sundays
EOF
