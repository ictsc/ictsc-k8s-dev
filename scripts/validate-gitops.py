#!/usr/bin/env python3
"""Render both GitOps trees and validate built-ins plus chart-provided CRDs, without cluster access."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.request

import yaml

# Kubernetes YAML treats the Alertmanager match operator '=' as a string.
yaml.SafeLoader.add_constructor('tag:yaml.org,2002:value', lambda loader, node: loader.construct_scalar(node))

ROOT = Path(__file__).resolve().parent.parent
OWN_REPO = 'git@github.com:ictsc/ictsc-k8s-dev.git'
KUBERNETES = '1.36.0'
BOOTSTRAP_SCHEMAS = [
    'https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/experimental-install.yaml',
    'https://raw.githubusercontent.com/cilium/cilium/v1.20.1/pkg/k8s/apis/cilium.io/client/crds/v2/ciliumloadbalancerippools.yaml',
    'https://raw.githubusercontent.com/cilium/cilium/v1.20.1/pkg/k8s/apis/cilium.io/client/crds/v2alpha1/ciliuml2announcementpolicies.yaml',
]


def run(command):
    return subprocess.check_output(command, cwd=ROOT, text=True)


def documents(text):
    return [doc for doc in yaml.safe_load_all(text) if doc]


def source_render(item):
    app, source = item
    name = app['metadata']['name']
    namespace = app['spec']['destination']['namespace']
    if 'chart' in source or 'helm' in source:
        helm = source.get('helm', {})
        command = ['helm', 'template', helm.get('releaseName', name)]
        if 'chart' in source:
            command += [source['chart'], '--repo', source['repoURL'], '--version', source['targetRevision']]
        else:
            if source['repoURL'] != OWN_REPO:
                raise ValueError('Unsupported external Helm directory')
            command += [str(ROOT / source['path'])]
        command += ['--namespace', namespace, '--kube-version', KUBERNETES, '--include-crds']
        for api in ('monitoring.coreos.com/v1', 'monitoring.coreos.com/v1/ServiceMonitor',
                    'monitoring.coreos.com/v1/PodMonitor', 'cert-manager.io/v1', 'gateway.networking.k8s.io/v1'):
            command += ['--api-versions', api]
        for value_file in helm.get('valueFiles', []):
            path = ROOT / value_file.removeprefix('$values/') if value_file.startswith('$values/') else ROOT / source.get('path', '') / value_file
            if not path.is_file():
                raise ValueError(f'Missing Helm values: {path}')
            command += ['-f', str(path)]
        for parameter in helm.get('parameters', []):
            command += ['--set-string' if parameter.get('forceString') else '--set', parameter['name'] + '=' + parameter['value']]
        with tempfile.TemporaryDirectory() as temporary:
            if 'values' in helm or 'valuesObject' in helm:
                values = Path(temporary) / 'values.yaml'
                values.write_text(yaml.safe_dump(helm['valuesObject']) if 'valuesObject' in helm else helm['values'])
                command += ['-f', str(values)]
            output = run(command)
    elif 'path' in source:
        if source['repoURL'] == OWN_REPO:
            output = run(['kubectl', 'kustomize', str(ROOT / source['path'])])
        else:
            # Match Argo CD's external Kustomize source and replica transform.
            with tempfile.TemporaryDirectory() as temporary:
                settings = dict(source.get('kustomize', {}))
                settings['resources'] = [source['repoURL'] + '//' + source['path'] + '?ref=' + source['targetRevision']]
                Path(temporary, 'kustomization.yaml').write_text(yaml.safe_dump(settings))
                output = run(['kubectl', 'kustomize', temporary])
    else:
        return []
    print(f'Rendered {name}: {source.get("chart", source.get("path"))}', flush=True)
    return documents(output)


def normalize(schema):
    if isinstance(schema, list):
        return [normalize(x) for x in schema]
    if not isinstance(schema, dict):
        return schema
    schema = {key: normalize(value) for key, value in schema.items()}
    if schema.get('x-kubernetes-int-or-string'):
        schema.pop('type', None)
        schema['anyOf'] = [{'type': 'integer'}, {'type': 'string'}]
    if schema.pop('nullable', False) and isinstance(schema.get('type'), str):
        schema['type'] = [schema['type'], 'null']
    return schema


def prune_null_fields(value, schema):
    # Kubernetes prunes non-nullable null object fields before CRD validation.
    # Required fields still fail as missing; explicitly nullable fields remain.
    if isinstance(value, dict):
        result = {}
        for key, child in value.items():
            child_schema = schema.get('properties', {}).get(key, schema.get('additionalProperties', {}))
            child_schema = child_schema if isinstance(child_schema, dict) else {}
            if child is not None or child_schema.get('nullable'):
                result[key] = prune_null_fields(child, child_schema)
        return result
    if isinstance(value, list):
        return [prune_null_fields(child, schema.get('items', {})) for child in value]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', choices=['dev', 'prod'], required=True)
    args = parser.parse_args()
    root = documents(run(['kubectl', 'kustomize', f'manifest/envs/{args.environment}']))
    rendered = list(root)
    pending = [doc for doc in root if doc.get('kind') == 'Application']
    visited = set()
    with ThreadPoolExecutor(max_workers=4) as pool:
        while pending:
            sources = []
            for app in pending:
                for source in app['spec'].get('sources', [app['spec'].get('source', {})]):
                    key = json.dumps([app['metadata']['name'], source], sort_keys=True)
                    if key not in visited:
                        visited.add(key)
                        sources.append((app, source))
            pending = []
            for docs in pool.map(source_render, sources):
                rendered.extend(docs)
                pending.extend(doc for doc in docs if doc.get('kind') == 'Application')
    # Include inactive workload overlays as well as the currently deployed tree.
    for directory in sorted((ROOT / 'manifest/base/apps/regalia/workload/overlays').iterdir()):
        if (directory / 'kustomization.yaml').exists():
            rendered.extend(documents(run(['kubectl', 'kustomize', str(directory)])))
    crds = [doc for doc in rendered if doc.get('kind') == 'CustomResourceDefinition']
    for url in BOOTSTRAP_SCHEMAS:
        with urllib.request.urlopen(url, timeout=60) as response:
            crds.extend(doc for doc in documents(response.read().decode()) if doc.get('kind') == 'CustomResourceDefinition')
    with tempfile.TemporaryDirectory(prefix='gitops-validation-') as temporary:
        directory = Path(temporary)
        custom_schemas = {}
        for crd in crds:
            spec = crd['spec']
            for version in spec['versions']:
                if not version.get('served') or 'schema' not in version:
                    continue
                schema = normalize(version['schema']['openAPIV3Schema'])
                custom_schemas[(spec['group'] + '/' + version['name'], spec['names']['kind'])] = version['schema']['openAPIV3Schema']
                path = directory / spec['group'] / f"{spec['names']['kind'].lower()}_{version['name']}.json"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(schema))
        manifests = directory / 'rendered.yaml'
        manifests.write_text(yaml.safe_dump_all(
            prune_null_fields(doc, custom_schemas[(doc['apiVersion'], doc['kind'])])
            if (doc['apiVersion'], doc['kind']) in custom_schemas else doc for doc in rendered))
        subprocess.run(['kubeconform', '-strict', '-summary', '-kubernetes-version', KUBERNETES,
                        # Vendor CRD definitions supply schemas; they are not workload instances.
                        '-skip', 'CustomResourceDefinition',
                        '-schema-location', str(directory / '{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'),
                        '-schema-location', 'default', str(manifests)], check=True)


if __name__ == '__main__':
    main()
