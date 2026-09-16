#!/usr/bin/env python3
"""Seed prod GitOps credentials without writing secret values to disk or stdout."""
import base64
import json
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parent.parent
DEV = ['kubectl', '--kubeconfig', str(ROOT / '.kube/config'), '--context', 'admin@ictsc-dev']
PROD = ['kubectl', '--kubeconfig', str(ROOT / '.kube/prod')]


def read(command):
    return json.loads(subprocess.check_output(command))


def apply(obj):
    subprocess.run(PROD + ['apply', '-f', '-'], input=json.dumps(obj).encode(), check=True, stdout=subprocess.DEVNULL)


def put(namespace, name, data, labels=None, encoded=False):
    existing = subprocess.check_output(PROD + ['-n', namespace, 'get', 'secret', name, '--ignore-not-found', '-o', 'name'])
    if existing:
        print(f'Preserved {namespace}/{name}')
        return
    apply({'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
           'metadata': {'name': name, 'namespace': namespace, 'labels': labels or {}},
           'data' if encoded else 'stringData': data})
    print(f'Created {namespace}/{name}')


nodes = read(PROD + ['get', 'nodes', '-o', 'json'])['items']
assert len(nodes) == 6 and all(n['metadata']['name'].startswith('ictsc-prod-') for n in nodes), 'Expected prod nodes'
for namespace in ['argocd', 'dex', 'oauth2-proxy', 'monitoring', 'scoreserver']:
    apply({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': namespace}})

repo = read(DEV + ['-n', 'argocd', 'get', 'secret', 'repo-ictsc-k8s-dev', '-o', 'json'])
put('argocd', 'repo-ictsc-k8s-dev', repo['data'], {'argocd.argoproj.io/secret-type': 'repository'}, encoded=True)
existing = read(PROD + ['-n', 'dex', 'get', 'secret', 'dex-secrets', '--ignore-not-found', '-o', 'json']) if subprocess.check_output(PROD + ['-n', 'dex', 'get', 'secret', 'dex-secrets', '--ignore-not-found', '-o', 'name']) else None
if existing:
    dex = {k: base64.b64decode(v).decode() for k, v in existing['data'].items()}
else:
    source = read(DEV + ['-n', 'dex', 'get', 'secret', 'dex-secrets', '-o', 'json'])['data']
    dex = {k: base64.b64decode(source[k]).decode() for k in ['github-client-id', 'github-client-secret']}
    dex.update({k: secrets.token_urlsafe(32) for k in ['oauth2-proxy-client-secret', 'argocd-client-secret', 'grafana-client-secret']})
put('dex', 'dex-secrets', dex)
put('oauth2-proxy', 'oidc', {'client-id': 'oauth2-proxy', 'client-secret': dex['oauth2-proxy-client-secret'], 'cookie-secret': secrets.token_urlsafe(32)})
put('argocd', 'argocd-oidc', {'clientSecret': dex['argocd-client-secret']}, {'app.kubernetes.io/part-of': 'argocd'})
put('monitoring', 'grafana-oidc', {'clientSecret': dex['grafana-client-secret']})
put('monitoring', 'grafana-admin', {'admin-user': 'admin', 'admin-password': secrets.token_urlsafe(32)})

# Regalia reuses the approved Discord App; callbacks include the prod hostname.
if not subprocess.check_output(PROD + ['-n', 'scoreserver', 'get', 'secret', 'discord-oauth-client', '--ignore-not-found', '-o', 'name']):
    discord = read(DEV + ['-n', 'scoreserver', 'get', 'secret', 'discord-oauth-client', '-o', 'json'])
    put('scoreserver', 'discord-oauth-client', {k: discord['data'][k] for k in ['client-id', 'client-secret']}, encoded=True)
