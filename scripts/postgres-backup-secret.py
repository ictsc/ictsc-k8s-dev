#!/usr/bin/env python3
"""Transfer bucket-scoped Terraform credentials without logging/writing values."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('environment', choices=['dev', 'prod'])
    args = parser.parse_args()
    kube = ['kubectl', '--kubeconfig', str(ROOT / '.kube' / ('config' if args.environment == 'dev' else 'prod')),
            '--request-timeout=30s']
    if args.environment == 'dev':
        kube += ['--context', 'admin@ictsc-dev']
    nodes = json.loads(subprocess.check_output(kube + ['get', 'nodes', '-o', 'json']))['items']
    if not nodes or not all(n['metadata']['name'].startswith(f'ictsc-{args.environment}-') for n in nodes):
        raise SystemExit('Unexpected target cluster')
    # Secret Manager is the recovery source, independent of cluster state.
    import importlib.util
    spec = importlib.util.spec_from_file_location('recovery', ROOT / 'scripts/recovery-secrets.py')
    recovery = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(recovery)
    data = json.loads(recovery.Vault().get(args.environment + '-postgres-s3'))
    if not data or any(not data.get(key) for key in ('ACCESS_KEY_ID', 'ACCESS_SECRET_KEY')):
        raise SystemExit('Backup credentials are incomplete')
    secret = {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
              'metadata': {'name': 'postgres-backup-s3', 'namespace': 'scoreserver',
                           'labels': {'cnpg.io/reload': 'true'}}, 'stringData': data}
    result = subprocess.run(kube + ['apply', '--server-side', '--field-manager=postgres-backup-bootstrap', '-f', '-'],
                            input=json.dumps(secret), text=True, capture_output=True)
    if result.returncode:
        raise SystemExit('Backup Secret update failed; no credentials logged')
    print(f'{args.environment}: scoreserver/postgres-backup-s3 configured')


if __name__ == '__main__':
    main()
