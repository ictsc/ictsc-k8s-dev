#!/usr/bin/env python3
"""Restore into a fresh, isolated namespace; never change the source database."""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('environment', choices=['dev', 'prod'])
    parser.add_argument('--namespace', required=True, help='New namespace starting with restore-check-')
    args = parser.parse_args()
    ns = args.namespace
    if not re.fullmatch(r'restore-check-[a-z0-9][a-z0-9-]{0,35}[a-z0-9]', ns):
        raise SystemExit('Use a unique namespace starting with restore-check-')
    kube = ['kubectl', '--kubeconfig', str(ROOT / '.kube' / ('config' if args.environment == 'dev' else 'prod')),
            '--request-timeout=30s']
    if args.environment == 'dev':
        kube += ['--context', 'admin@ictsc-dev']

    def read(*command):
        return json.loads(subprocess.check_output(kube + list(command) + ['-o', 'json']))

    def apply(obj, create=False):
        result = subprocess.run(kube + ['create' if create else 'apply', '-f', '-'],
                                input=json.dumps(obj), text=True, capture_output=True)
        if result.returncode:
            raise SystemExit('Restore resource creation failed; inspect the isolated namespace. No secret data logged.')

    nodes = read('get', 'nodes')['items']
    if not nodes or not all(n['metadata']['name'].startswith(f'ictsc-{args.environment}-') for n in nodes):
        raise SystemExit('Unexpected source cluster')
    source = read('-n', 'scoreserver', 'get', 'cluster.postgresql.cnpg.io', 'postgres')
    store = read('-n', 'scoreserver', 'get', 'objectstore', 'postgres-backups')
    secret = read('-n', 'scoreserver', 'get', 'secret', 'postgres-backup-s3')
    # Never reuse an existing namespace, even one left by an earlier failed run.
    apply({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': ns,
           'labels': {'ictsc.net/purpose': 'restore-check'}}}, create=True)
    started = time.monotonic()
    apply({'apiVersion': 'networking.k8s.io/v1', 'kind': 'NetworkPolicy',
           'metadata': {'name': 'operator-only', 'namespace': ns},
           'spec': {'podSelector': {}, 'policyTypes': ['Ingress'], 'ingress': [{
               'from': [{'namespaceSelector': {'matchLabels': {'kubernetes.io/metadata.name': 'cnpg-system'}}}],
               'ports': [{'protocol': 'TCP', 'port': 8000}],
           }]}})
    apply({'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': 'postgres-backup-s3', 'namespace': ns},
           'type': 'Opaque', 'data': secret['data']}, create=True)
    # No retention policy and no WAL archiver: a recovery drill must not prune
    # the source backup or start writing into its archive.
    apply({'apiVersion': store['apiVersion'], 'kind': 'ObjectStore',
           'metadata': {'name': 'postgres-source', 'namespace': ns},
           'spec': {'configuration': store['spec']['configuration'],
                    'instanceSidecarConfiguration': store['spec'].get('instanceSidecarConfiguration', {})}})
    apply({'apiVersion': 'postgresql.cnpg.io/v1', 'kind': 'Cluster',
           'metadata': {'name': 'postgres-restore', 'namespace': ns},
           'spec': {'instances': 1, 'imageName': source['spec']['imageName'],
                    'storage': source['spec']['storage'],
                    'resources': source['spec'].get('resources', {}),
                    'bootstrap': {'recovery': {'source': 'postgres-source'}},
                    'externalClusters': [{'name': 'postgres-source', 'plugin': {
                        'name': 'barman-cloud.cloudnative-pg.io',
                        'parameters': {'barmanObjectName': 'postgres-source', 'serverName': 'postgres'}}}]}})
    print(f'Restoring into {ns}/postgres-restore; source remains unchanged', flush=True)
    subprocess.run(kube + ['-n', ns, 'wait', '--for=condition=Ready', 'clusters.postgresql.cnpg.io/postgres-restore', '--timeout=15m'], check=True)
    query = "SELECT json_build_object('teams',(SELECT count(*) FROM teams),'content_snapshots',(SELECT count(*) FROM content_snapshots),'answers',(SELECT count(*) FROM answers),'marking_results',(SELECT count(*) FROM marking_results));"
    result = subprocess.run(kube + ['-n', ns, 'exec', 'postgres-restore-1', '-c', 'postgres', '--',
                                    'psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-d', 'ictscore_openapi', '-c', query],
                            text=True, capture_output=True)
    if result.returncode:
        raise SystemExit('Restore SQL verification failed; inspect the isolated cluster')
    print(f'Restore SQL succeeded in {int(time.monotonic() - started)} seconds: {result.stdout.strip()}')
    print('After reviewing results, remove only this drill namespace: ' + shlex.join(kube + ['delete', 'namespace', ns]))


if __name__ == '__main__':
    main()
