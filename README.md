# restic-backup-kit

Automated, encrypted [restic](https://restic.net/) backups for Linux servers, with the part most setups skip: **regularly proving the backup can actually be restored.**

- **`restic-backup`**: one backup + retention cycle, driven by a single config file. Daily via a systemd timer.
- **`restic-restore-test`**: restores a random sample of files from the latest snapshot, compares them byte-for-byte (SHA-256) with the live files, re-reads part of the repository with `restic check`, and fails loudly if backups have stopped. Weekly via a systemd timer.
- Optional **healthchecks.io-style monitoring**, so you are alerted when a run fails *and* when a run never happens.

```
$ sudo restic-restore-test
2026-10-14 06:00:02 restic-restore-test 0.1.0: repository sftp:backup@nas:/srv/restic/web01
2026-10-14 06:00:03 latest snapshot 5543c032 from 2026-10-14T02:41:17-03:00 (3h ago)
2026-10-14 06:00:09 restored 20 file(s), 18734 KiB in 6s: 18 identical to the live file, 2 changed since the snapshot (restore-only)
2026-10-14 06:00:09 verifying repository data (read-data-subset=2%)
2026-10-14 06:00:31 RESTORE TEST PASSED
```

## Why the restore test matters

A backup job that reports "success" every night tells you that *something* was written, not that you can get your data back. The restore test catches the failures that usually surface on the worst possible day:

| Failure | How it is caught |
|---|---|
| Backups silently stopped (timer disabled, disk full, credentials expired) | Newest snapshot older than `RESTORE_TEST_MAX_AGE_HOURS` → FAIL |
| Repository corruption (bad disk, broken NAS, bit rot in object storage) | `restic restore` and `restic check --read-data-subset` → FAIL |
| Backed-up data differs from what is on disk although the file was not modified | SHA-256 mismatch for files whose mtime predates the snapshot → FAIL |
| Files changed after the backup | Restored and counted as restore-only, **no false alarm** |

## Install

Debian/Ubuntu (restic, jq and curl are installed automatically):

```bash
git clone https://github.com/francisco-vilaca/restic-backup-kit.git
cd restic-backup-kit
sudo ./install.sh
```

`install.sh` copies the two scripts to `/usr/local/bin`, creates `/etc/restic-backup-kit/` (mode 700) with a config template, an excludes file and a **randomly generated repository password**, and installs the systemd units. It never overwrites an existing config or password, so it is safe to re-run.

Then:

```bash
sudo nano /etc/restic-backup-kit/backup.env   # set RESTIC_REPOSITORY and BACKUP_PATHS
sudo restic-backup --init                     # first backup, creates the repository
sudo restic-restore-test                      # prove it restores
sudo ./install.sh --enable                    # daily backup ~02:30, restore test on Sundays ~06:00
```

> **Save the password** in `/etc/restic-backup-kit/password` somewhere outside the server. Restic encrypts everything; without the password nobody can restore the data, including you.

## Configuration

Everything lives in [`/etc/restic-backup-kit/backup.env`](config/backup.env.example):

| Variable | Default | Purpose |
|---|---|---|
| `RESTIC_REPOSITORY` | | Local path, `sftp:`, `s3:` (AWS, Backblaze B2, Wasabi, MinIO), or any restic backend |
| `RESTIC_PASSWORD_FILE` | `/etc/restic-backup-kit/password` | Repository password |
| `BACKUP_PATHS` | `/etc /home /root /var/www /srv` | Space-separated; paths that don't exist are skipped with a warning |
| `EXCLUDE_FILE` | `/etc/restic-backup-kit/excludes.txt` | Caches, `node_modules`, temp files |
| `PRE_BACKUP_HOOK` | | Command run first, e.g. a consistent `mysqldump` or `pg_dumpall` |
| `KEEP_LAST` / `DAILY` / `WEEKLY` / `MONTHLY` | 3 / 7 / 4 / 6 | Retention, applied with `forget --prune` after each backup |
| `ALLOW_INCOMPLETE` | `no` | Treat "some files could not be read" as a failure |
| `CHECK_READ_DATA_SUBSET` | | Also verify part of the data after each backup (e.g. `1%`) |
| `RESTORE_TEST_FILES` | `20` | Random files restored per test |
| `RESTORE_TEST_MAX_AGE_HOURS` | `26` | Alert when the newest snapshot is older than this |
| `RESTORE_TEST_CHECK_SUBSET` | `2%` | Share of repository data re-read by the restore test |
| `HEALTHCHECK_URL`, `RESTORE_TEST_HEALTHCHECK_URL` | | Ping URLs; `/start` and `/fail` are appended automatically |

Other details:

- Runs never overlap (`flock`): if a backup is still running when the next one starts, the new run exits cleanly.
- Backups run with `nice` and idle I/O priority, so they don't slow the server down.
- Snapshots are tagged `restic-backup-kit`, and retention only touches snapshots with that tag.
- Exit codes: `0` success, `1` failure, `2` configuration error. They work with any monitoring tool.

## Tests

`tests/test.sh` runs end-to-end against a throwaway local repository (no root needed, nothing outside a temp dir is touched). It covers 18 checks: init guard, missing paths, excludes, retention, concurrent-run locking, SHA-256 verification of every restored file, no false alarm for files changed after the backup, detection of content that differs from the backup, stale-backup alerting, and **a deliberately corrupted repository pack file being detected**.

```bash
sudo apt-get install -y restic jq
bash tests/test.sh
```

CI runs `shellcheck` and the full test suite on every push.

## License

MIT, see [LICENSE](LICENSE).
