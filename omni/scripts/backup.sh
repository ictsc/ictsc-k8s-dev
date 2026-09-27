#!/usr/bin/env bash
# Run on the Omni VM with root privileges and a configured encrypted restic repo.
set -euo pipefail
set +x
umask 077
: "${RESTIC_REPOSITORY:?Set an off-host restic repository}"
: "${RESTIC_PASSWORD_FILE:?Set a root-only password file; keep a recovery copy off-host}"
[[ $(id -u) == 0 ]] || { echo 'Run as root' >&2; exit 1; }
for tool in etcdctl etcdutl restic python3 flock; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
[[ -s "$RESTIC_PASSWORD_FILE" && -s /opt/omni/omni.asc && -s /var/lib/omni/sqlite/omni.db ]]
install -d -m 0700 /var/lib/omni-backup
exec 9>/var/lib/omni-backup/backup.lock
flock -n 9 || { echo 'Another backup is running' >&2; exit 1; }
stage=$(mktemp -d /var/lib/omni-backup/snapshot.XXXXXXXX)
trap 'rm -rf -- "$stage"' EXIT
# etcdctl / etcdutl must match the running embedded etcd major/minor version.
etcdctl --endpoints=http://127.0.0.1:2379 --command-timeout=60s snapshot save "$stage/etcd.snapshot"
etcdutl snapshot status "$stage/etcd.snapshot" --write-out=json > "$stage/etcd-status.json"
python3 - "$stage" <<'PY'
import pathlib
import sqlite3
import sys
stage = pathlib.Path(sys.argv[1])
with sqlite3.connect('file:/var/lib/omni/sqlite/omni.db?mode=ro', uri=True) as source:
    with sqlite3.connect(stage / 'omni.db') as target:
        source.backup(target)
        if target.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise SystemExit('SQLite integrity check failed')
PY
# Capture only selected recovery material, never the restic password itself.
tar -C / -czf "$stage/config.tar.gz" opt/omni etc/letsencrypt
date -u +%FT%TZ > "$stage/created-at"
# --host and --tag give retention a stable group despite changing temp paths.
restic backup --host ictsc-omni --tag omni-recovery "$stage"
date -u +%FT%TZ > /var/lib/omni-backup/last-success
echo 'Omni etcd/SQLite/config backup completed; live services were not stopped'
