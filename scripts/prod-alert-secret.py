#!/usr/bin/env python3
"""Create the prod notification Secret; never overwrite an existing destination."""
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
KUBECTL = ['kubectl', '--kubeconfig', str(ROOT / '.kube/prod'), '--request-timeout=30s']


def main():
    nodes = json.loads(subprocess.check_output(KUBECTL + ['get', 'nodes', '-o', 'json']))['items']
    if not nodes or not all(n['metadata']['name'].startswith('ictsc-prod-') for n in nodes):
        raise SystemExit('Expected prod nodes; refusing to write Secret')
    existing = subprocess.check_output(KUBECTL + ['-n', 'monitoring', 'get', 'secret',
                                                'alertmanager-discord', '--ignore-not-found', '-o', 'name'])
    if existing:
        print('Preserved monitoring/alertmanager-discord')
        return
    webhook = os.environ.get('PROD_DISCORD_WEBHOOK_URL', '')
    parsed = urlparse(webhook)
    if parsed.scheme != 'https' or parsed.netloc != 'discord.com' or not parsed.path.startswith('/api/webhooks/'):
        raise SystemExit('Set PROD_DISCORD_WEBHOOK_URL to the approved prod Discord webhook')
    secret = {
        'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
        'metadata': {'name': 'alertmanager-discord', 'namespace': 'monitoring'},
        'stringData': {'webhook-url': webhook},
    }
    # create is atomic and does not store a second copy in last-applied-configuration.
    result = subprocess.run(KUBECTL + ['create', '-f', '-'], input=json.dumps(secret),
                            text=True, capture_output=True)
    if result.returncode:
        raise SystemExit('Failed to create notification Secret; check API access and existing resources')
    print('Created monitoring/alertmanager-discord')


if __name__ == '__main__':
    main()
