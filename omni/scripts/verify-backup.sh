#!/usr/bin/env bash
# Restore to a NEW empty directory. Does not start Omni or contact managed nodes.
set -euo pipefail
set +x
umask 077
snapshot=${1:?usage: verify-backup.sh SNAPSHOT_ID NEW_DIRECTORY}
destination=${2:?usage: verify-backup.sh SNAPSHOT_ID NEW_DIRECTORY}
: "${RESTIC_REPOSITORY:?Required}"
: "${RESTIC_PASSWORD_FILE:?Required}"
[[ ! -e "$destination" ]] || { echo 'Destination already exists; refusing to overwrite' >&2; exit 1; }
for tool in restic etcdutl python3; do command -v "$tool" >/dev/null; done
mkdir -m 0700 -- "$destination"
restic restore "$snapshot" --host ictsc-omni --tag omni-recovery --target "$destination"
python3 - "$destination" <<'PY'
import pathlib
import sqlite3
import subprocess
import sys
import tarfile
root = pathlib.Path(sys.argv[1]).resolve()
snapshots = list(root.glob('var/lib/omni-backup/snapshot.*/etcd.snapshot'))
if len(snapshots) != 1:
    raise SystemExit('Expected exactly one Omni snapshot')
stage = snapshots[0].parent
subprocess.run(['etcdutl', 'snapshot', 'status', str(snapshots[0]), '--write-out=json'], check=True)
subprocess.run(['etcdutl', 'snapshot', 'restore', str(snapshots[0]), '--data-dir', str(root / 'etcd-restore-check')], check=True)
with sqlite3.connect(f'file:{stage / "omni.db"}?mode=ro', uri=True) as database:
    if database.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        raise SystemExit('SQLite integrity check failed')
with tarfile.open(stage / 'config.tar.gz') as archive:
    names = set(archive.getnames())
    required = {'opt/omni/omni.asc', 'opt/omni/compose.yaml', 'opt/omni/omni.env', 'opt/omni/dex.yaml'}
    if not required <= names:
        raise SystemExit('Missing key/config recovery material')
print('etcd restore, SQLite integrity, and required recovery files verified; Omni not started')
PY
