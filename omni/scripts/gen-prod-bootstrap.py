#!/usr/bin/env python3
"""Build prod NoCloud media with only networking and Omni join configuration."""
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys

os.umask(0o077)
root = Path(__file__).resolve().parents[2]
config = json.loads(Path(sys.argv[1]).read_text())
if config['cluster_name'] != 'ictsc-prod':
    raise SystemExit('Only ictsc-prod may use this bootstrap path')
join = (root / '.omni/prod-join.yaml').read_text()
if 'SideroLinkConfig' not in join:
    raise SystemExit('Download .omni/prod-join.yaml with omnictl jointoken machine-config first')
build = root / 'talos/build/ictsc-prod'
for folder in ['config', 'iso', 'patches']:
    (build / folder).mkdir(parents=True, exist_ok=True)
for node in config['nodes']:
    hostname = node['hostname']
    docs = [
        {'apiVersion': 'v1alpha1', 'kind': 'HostnameConfig', 'auto': 'off', 'hostname': hostname},
        {'apiVersion': 'v1alpha1', 'kind': 'ResolverConfig',
         'nameservers': [{'address': address} for address in config['nameservers']]},
    ]
    for alias, bus, address in [
        ('external', '0000:00:03.0', f"{node['external_ip']}/{ipaddress.ip_network(config['external_cidr']).prefixlen}"),
        ('internal', '0000:00:04.0', f"{node['internal_ip']}/{ipaddress.ip_network(config['internal_network']).prefixlen}"),
    ]:
        docs.append({'apiVersion': 'v1alpha1', 'kind': 'LinkAliasConfig', 'name': alias,
                     'selector': {'match': f'link.bus_path == "{bus}"'}})
        link = {'apiVersion': 'v1alpha1', 'kind': 'LinkConfig', 'name': alias,
                'up': True, 'addresses': [{'address': address}]}
        if alias == 'external':
            link['routes'] = [{'gateway': config['external_gateway']}]
        docs.append(link)
    patch_text = '\n---\n'.join(json.dumps(doc, indent=2) for doc in docs) + '\n'
    (build / 'patches' / f'{hostname}.yaml').write_text(patch_text)
    # No v1alpha1 machine/cluster config: Omni supplies PKI and role after joining.
    body = patch_text + '---\n' + join
    destination = build / 'config' / f'{hostname}.yaml'
    if destination.exists() and destination.read_text() != body:
        raise SystemExit(f'Refusing to replace existing bootstrap config: {destination}')
    destination.write_text(body)
    subprocess.run(["talosctl", "validate", "--config", str(destination), "--mode", "cloud"], check=True)
    media = build / 'iso' / f'{hostname}.iso'
    if not media.exists():
        source = build / 'cidata' / hostname
        source.mkdir(parents=True, exist_ok=True)
        (source / 'user-data').write_text(body)
        (source / 'meta-data').write_text(f'instance-id: {hostname}\nlocal-hostname: {hostname}\n')
        subprocess.run(['bash', str(root / 'talos/scripts/build-iso.sh'), str(source), str(media)], check=True)
    print(f'{hostname}: bootstrap media ready')
