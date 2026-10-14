#!/usr/bin/env bash
# End-to-end tests against a throwaway local repository. Needs restic, jq, shuf.
# Does not touch /etc: everything lives in a temporary directory.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BACKUP="$ROOT/bin/restic-backup"
RESTORE_TEST="$ROOT/bin/restic-restore-test"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
PASS=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; exit 1; }
expect_exit() { # expect_exit CODE DESCRIPTION CMD...
  local want=$1 desc=$2 rc=0
  shift 2
  "$@" >"$W/out.log" 2>&1 || rc=$?
  [[ $rc -eq $want ]] || { cat "$W/out.log" >&2; fail "$desc (exit $rc, expected $want)"; }
  ok "$desc"
}
snapshots() { RESTIC_PASSWORD_FILE="$W/pass" restic -r "$W/repo" snapshots --json | jq length; }

# --- fixture: a small "server" with nested dirs, spaces and binary data ---
mkdir -p "$W/src/etc/app" "$W/src/www/site files" "$W/src/www/cache"
for i in $(seq 1 25); do head -c $((RANDOM + 100)) /dev/urandom >"$W/src/www/site files/file $i.bin"; done
for i in $(seq 1 10); do echo "setting_$i = $RANDOM" >"$W/src/etc/app/conf$i.ini"; done
echo "temporary" >"$W/src/www/cache/x.tmp"
touch -d '2 hours ago' "$W"/src/etc/app/* "$W"/src/www/site\ files/*
echo "*.tmp" >"$W/excludes.txt"
echo "test-password" >"$W/pass"

cat >"$W/backup.env" <<EOF
RESTIC_REPOSITORY=$W/repo
RESTIC_PASSWORD_FILE=$W/pass
BACKUP_PATHS="$W/src/etc $W/src/www $W/src/does-not-exist"
EXCLUDE_FILE=$W/excludes.txt
KEEP_LAST=3
RESTORE_TEST_FILES=1000
RESTORE_TEST_CHECK_SUBSET=100%
LOCK_FILE=$W/lock
EOF
export RESTIC_KIT_CONFIG="$W/backup.env" RESTIC_CACHE_DIR="$W/cache"

echo "backup"
expect_exit 1 "refuses to run against an uninitialized repo without --init" "$BACKUP"
expect_exit 0 "first backup with --init" "$BACKUP" --init
grep -q "does-not-exist does not exist, skipping" "$W/out.log" && ok "missing paths are skipped with a warning"
[[ $(snapshots) -eq 1 ]] && ok "one snapshot created"
RESTIC_PASSWORD_FILE="$W/pass" restic -r "$W/repo" ls latest >"$W/ls.txt"
if grep -q 'x.tmp' "$W/ls.txt"; then fail "excluded file was backed up"; fi
ok "exclude file honored"

for _ in 1 2 3 4 5 6; do "$BACKUP" >/dev/null 2>&1; done
# 7 backups in one day: keep-last 3 plus restic's daily/weekly/monthly buckets
[[ $(snapshots) -le 4 ]] && ok "retention prunes old snapshots (7 backups -> $(snapshots) kept)"

echo "lock"
exec 8>"$W/lock"; flock 8
expect_exit 0 "second concurrent run exits cleanly" "$BACKUP"
grep -q "still running" "$W/out.log" && ok "concurrent run is skipped"
exec 8>&-

echo "restore test"
expect_exit 0 "restore test passes on a healthy backup" "$RESTORE_TEST"
grep -Eq "35 identical to the live file" "$W/out.log" && ok "all 35 files restored and verified by SHA-256"

echo "changed since snapshot" >>"$W/src/etc/app/conf1.ini"
expect_exit 0 "files changed after the backup are not false alarms" "$RESTORE_TEST"
grep -q "1 changed since the snapshot" "$W/out.log" && ok "changed file reported as restore-only"

# Silent corruption: content changes but the timestamp claims it did not.
printf 'X' | dd of="$W/src/etc/app/conf2.ini" bs=1 seek=0 conv=notrunc status=none
touch -d '2 hours ago' "$W/src/etc/app/conf2.ini"
expect_exit 1 "detects content that differs from the backup" "$RESTORE_TEST"
grep -q "content differs" "$W/out.log" && ok "mismatch is reported by path"
"$BACKUP" >/dev/null 2>&1   # back up the new state so the next tests start clean

echo "monitoring"
RESTORE_TEST_MAX_AGE_HOURS=0 expect_exit 1 "stale backups are flagged" env RESTORE_TEST_MAX_AGE_HOURS=0 "$RESTORE_TEST"
grep -q "backups have stopped" "$W/out.log" && ok "age problem explained"

echo "repository corruption"
pack=$(find "$W/repo/data" -type f | head -1)
chmod u+w "$pack"
printf 'corrupted!!' | dd of="$pack" bs=1 seek=100 conv=notrunc status=none
expect_exit 1 "detects a corrupted repository" "$RESTORE_TEST"
grep -Eq "restic check found errors|restic restore failed" "$W/out.log" && ok "corruption reported"

echo ""
EXPECTED=18
[[ $PASS -eq $EXPECTED ]] || fail "only $PASS of $EXPECTED checks passed"
echo "$PASS checks passed"
