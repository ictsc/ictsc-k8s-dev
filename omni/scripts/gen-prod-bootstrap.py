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
    network = {
        'hostname': hostname,
        'nameservers': config['nameservers'],
        'interfaces': [
            {'interface': 'eth0', 'dhcp': False,
             'addresses': [f"{node['external_ip']}/{ipaddress.ip_network(config['external_cidr']).prefixlen}"],
             'routes': [{'network': '0.0.0.0/0', 'gateway': config['external_gateway']}]},
            {'interface': 'eth1', 'dhcp': False,
             'addresses': [f"{node['internal_ip']}/{ipaddress.ip_network(config['internal_network']).prefixlen}"]},
        ],
    }
    patch = {'machine': {'network': network}}
    patch_text = json.dumps(patch, indent=2) + '\n'
    (build / 'patches' / f'{hostname}.yaml').write_text(patch_text)
    # Partial v1alpha1 config is combined with SideroLink/EventSink/Kmsg documents.
    bootstrap = {'version': 'v1alpha1', **patch}
    body = json.dumps(bootstrap, indent=2) + '\n---\n' + join
    destination = build / 'config' / f'{hostname}.yaml'
    if destination.exists() and destination.read_text() != body:
        raise SystemExit(f'Refusing to replace existing bootstrap config: {destination}')
    destination.write_text(body)
    media = build / 'iso' / f'{hostname}.iso'
    if not media.exists():
        source = build / 'cidata' / hostname
        source.mkdir(parents=True, exist_ok=True)
        (source / 'user-data').write_text(body)
        (source / 'meta-data').write_text(f'instance-id: {hostname}\nlocal-hostname: {hostname}\n')
        subprocess.run(['bash', str(root / 'talos/scripts/build-iso.sh'), str(source), str(media)], check=True)
    print(f'{hostname}: bootstrap media ready')
