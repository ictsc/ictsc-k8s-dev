#!/usr/bin/env python3
"""Keep recovery credentials in Sakura Secret Manager; never print values."""
import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def run_json(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('Credential source failed; output suppressed')
    return json.loads(result.stdout)


class Vault:
    def __init__(self):
        self.storage = run_json(['bash', str(ROOT / 'scripts/backup-infra.sh'), 'output', '-json', 'storage'])
        env = run_json(['bash', '-c', 'set -a; source "$1"; python3 -c \'import os,json; print(json.dumps({k:os.environ[k] for k in ("SAKURACLOUD_ACCESS_TOKEN","SAKURACLOUD_ACCESS_TOKEN_SECRET")}))\'',
                        'recovery-secrets', str(ROOT / '.omni/dev-sakura.env')])
        auth = base64.b64encode((env['SAKURACLOUD_ACCESS_TOKEN'] + ':' + env['SAKURACLOUD_ACCESS_TOKEN_SECRET']).encode()).decode()
        self.headers = {'Authorization': 'Basic ' + auth, 'Content-Type': 'application/json'}
        self.url = 'https://secure.sakura.ad.jp/cloud/zone/is1a/api/cloud/1.1/secretmanager/vaults/' + self.storage['vault_id'] + '/secrets'
        listing = self.api('GET', '?Count=100&From=0')
        if listing['Total'] != len(listing['Secrets']):
            raise RuntimeError('Incomplete vault listing; refusing to proceed')
        self.names = {s['Name'] for s in listing['Secrets']}

    def api(self, method, suffix='', body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.url + suffix, data=data, headers=self.headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f'Sakura Secret Manager HTTP {error.code}; response suppressed') from None
        except (urllib.error.URLError, ValueError):
            raise RuntimeError('Sakura Secret Manager request failed; response suppressed') from None

    def get(self, name):
        return self.api('POST', '/unveil', {'Secret': {'Name': name}})['Secret']['Value']

    def put(self, name, value):
        if len(value.encode()) > 65536:
            raise ValueError('Recovery value exceeds vault limit')
        if name in self.names:
            if self.get(name) != value:
                raise RuntimeError(f'Existing recovery value differs: {name}; not overwritten')
        else:
            self.api('POST', body={'Secret': {'Name': name, 'Value': value}})
            self.names.add(name)
        if self.get(name) != value:
            raise RuntimeError('Vault read-back mismatch')
        print(f'Verified Sakura recovery secret: {name}')


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def sync():
    vault = Vault()
    credentials = run_json(['bash', str(ROOT / 'scripts/backup-infra.sh'), 'output', '-json', 'credentials'])
    dev = run_json(['bash', str(ROOT / 'scripts/terraform-env.sh'), 'dev', 'output', '-json', 'postgres_backup_credentials'])
    vault.put('dev-postgres-s3', encode(dev))
    vault.put('prod-postgres-s3', encode(credentials['prod_postgres']))
    if 'omni-restic' not in vault.names:
        omni = {'credentials': credentials['omni'], 'password': secrets.token_urlsafe(48),
                'repository': 's3:https://' + vault.storage['endpoint'] + '/' + vault.storage['buckets']['omni'],
                'region': vault.storage['region']}
        vault.put('omni-restic', encode(omni))
    else:
        omni = json.loads(vault.get('omni-restic'))
        if omni['credentials'] != credentials['omni']:
            raise RuntimeError('Omni recovery credentials differ; not overwritten')
        print('Verified existing Omni recovery credentials')
    kube = ['kubectl', '--kubeconfig', str(ROOT / '.kube/prod'), '--request-timeout=30s']
    nodes = run_json(kube + ['get', 'nodes', '-o', 'json'])['items']
    if not nodes or any(not n['metadata']['name'].startswith('ictsc-prod-') for n in nodes):
        raise RuntimeError('Unexpected prod cluster')
    keys = ['argocd/repo-ictsc-k8s-dev', 'dex/dex-secrets', 'oauth2-proxy/oidc', 'argocd/argocd-oidc',
            'monitoring/grafana-oidc', 'monitoring/grafana-admin', 'scoreserver/discord-oauth-client']
    bundle = {'version': 1, 'environment': 'prod', 'secrets': {}}
    for key in keys:
        namespace, name = key.split('/')
        bundle['secrets'][key] = run_json(kube + ['-n', namespace, 'get', 'secret', name, '-o', 'json'])['data']
    vault.put('prod-gitops-v1', encode(bundle))
    discord = run_json(kube + ['-n', 'monitoring', 'get', 'secret', 'alertmanager-discord', '-o', 'json'])
    vault.put('prod-discord-webhook', base64.b64decode(discord['data']['webhook-url']).decode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export-prod', metavar='NEW_FILE', help='Recover the prod GitOps bundle into a new owner-only file')
    args = parser.parse_args()
    try:
        if args.export_prod:
            value = Vault().get('prod-gitops-v1')
            fd = os.open(args.export_prod, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as stream:
                stream.write(value)
            print('Recovered prod bundle to a new mode-600 file; remove after use')
        else:
            sync()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        if isinstance(error, RuntimeError):
            raise SystemExit(str(error)) from None
        raise SystemExit('Recovery operation failed; sensitive details suppressed') from None


if __name__ == '__main__':
    main()
