#!/usr/bin/env python3
"""Preserve prod Secrets or recover missing ones from a prod-only bundle."""
import argparse
import base64
import json
import os
from pathlib import Path
import stat
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PROD = ['kubectl', '--kubeconfig', str(ROOT / '.kube/prod'), '--request-timeout=30s']
REQUIRED = {
    'argocd/repo-ictsc-k8s-dev': ('type', 'url', 'sshPrivateKey'),
    'dex/dex-secrets': ('github-client-id', 'github-client-secret', 'oauth2-proxy-client-secret', 'argocd-client-secret', 'grafana-client-secret'),
    'oauth2-proxy/oidc': ('client-id', 'client-secret', 'cookie-secret'),
    'argocd/argocd-oidc': ('clientSecret',),
    'monitoring/grafana-oidc': ('clientSecret',),
    'monitoring/grafana-admin': ('admin-user', 'admin-password'),
    'scoreserver/discord-oauth-client': ('client-id', 'client-secret'),
}
LABELS = {
    'argocd/repo-ictsc-k8s-dev': {'argocd.argoproj.io/secret-type': 'repository'},
    'argocd/argocd-oidc': {'app.kubernetes.io/part-of': 'argocd'},
}


def read(*args):
    result = subprocess.run(PROD + list(args) + ['-o', 'json'], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('Kubernetes read failed; check prod credentials and API access')
    return json.loads(result.stdout) if result.stdout.strip() else None


def create(obj):
    # Atomic create protects Secrets concurrently created by another operator.
    result = subprocess.run(PROD + ['create', '-f', '-'], input=json.dumps(obj), text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('Kubernetes create failed; existing resources were not overwritten')


def validate_data(key, data):
    for field in REQUIRED[key]:
        try:
            if not base64.b64decode(data[field], validate=True):
                raise ValueError()
        except (KeyError, ValueError, TypeError):
            raise ValueError(f'Invalid or missing key: {key}/{field}') from None


def load_bundle(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid != os.getuid():
            raise ValueError('Recovery bundle must be an owner-only regular file (mode 600)')
        bundle = json.load(stream)
    if bundle.get('version') != 1 or bundle.get('environment') != 'prod':
        raise ValueError('Expected a version 1 prod recovery bundle')
    return bundle['secrets']


def check_oidc_consistency(data):
    dex = data['dex/dex-secrets']
    for source, target in [('oauth2-proxy-client-secret', 'oauth2-proxy/oidc'),
                           ('argocd-client-secret', 'argocd/argocd-oidc'),
                           ('grafana-client-secret', 'monitoring/grafana-oidc')]:
        field = 'client-secret' if target == 'oauth2-proxy/oidc' else 'clientSecret'
        if dex[source] != data[target][field]:
            raise ValueError(f'OIDC credentials disagree: dex/dex-secrets and {target}')


def reconcile(bundle_path=None, export_path=None):
    nodes = read('get', 'nodes')['items']
    if not nodes or not all(n['metadata']['name'].startswith('ictsc-prod-') for n in nodes):
        raise ValueError('Expected prod nodes; refusing to access credentials')
    current = {}
    for key in REQUIRED:
        namespace, name = key.split('/')
        obj = read('-n', namespace, 'get', 'secret', name, '--ignore-not-found')
        if obj:
            validate_data(key, obj.get('data', {}))
            current[key] = obj['data']
    missing = REQUIRED.keys() - current.keys()
    if export_path:
        if missing:
            raise ValueError('Cannot export incomplete prod credentials: ' + ', '.join(sorted(missing)))
        check_oidc_consistency(current)
        fd = os.open(export_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump({'version': 1, 'environment': 'prod', 'secrets': current}, stream)
        print('Exported owner-only prod recovery bundle; store it in the approved encrypted vault')
        return
    if not missing:
        check_oidc_consistency(current)
        print('Preserved all prod GitOps Secrets; no dev access or writes')
        return
    if not bundle_path:
        raise ValueError('Missing prod Secrets: ' + ', '.join(sorted(missing)) + '; set PROD_GITOPS_SECRETS_FILE')
    bundle = load_bundle(bundle_path)
    for key in missing:
        validate_data(key, bundle.get(key, {}))
    desired = dict(current)
    desired.update({key: bundle[key] for key in missing})
    # Validate all credentials before any write, including partially rotated OIDC.
    check_oidc_consistency(desired)
    for namespace in sorted({key.split('/')[0] for key in missing}):
        if not read('get', 'namespace', namespace, '--ignore-not-found'):
            create({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': namespace}})
    for key in sorted(missing):
        namespace, name = key.split('/')
        create({'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
                'metadata': {'name': name, 'namespace': namespace, 'labels': LABELS.get(key, {})},
                'data': desired[key]})
        print(f'Restored {key}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export', metavar='NEW_FILE', help='Export current prod credentials to a new mode-600 file')
    args = parser.parse_args()
    try:
        reconcile(os.environ.get('PROD_GITOPS_SECRETS_FILE'), args.export)
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        if isinstance(error, json.JSONDecodeError):
            raise SystemExit('Invalid recovery bundle JSON') from None
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()
