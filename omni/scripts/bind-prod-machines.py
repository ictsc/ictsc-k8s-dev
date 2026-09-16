#!/usr/bin/env python3
"""Match Terraform's prod addresses to connected Omni machines, without mutations."""
import ipaddress
import json
import os
from pathlib import Path
import subprocess

os.umask(0o077)
root = Path(__file__).resolve().parents[2]
expected = json.loads((root / '.omni/prod-input.json').read_text())
if expected['cluster_name'] != 'ictsc-prod' or len(expected['nodes']) != 6:
    raise SystemExit('Expected the six-node ictsc-prod input')
raw = subprocess.check_output([
    str(root / 'bin/omnictl'), '--omniconfig', str(root / '.omni/config'),
    'get', 'machinestatuses', '-o', 'json',
], text=True)
decoder = json.JSONDecoder()
records = []
while raw.strip():
    record, end = decoder.raw_decode(raw.lstrip())
    records.append(record)
    raw = raw.lstrip()[end:]
nodes = {}
for node in expected['nodes']:
    matches = [r for r in records if r['spec'].get('network', {}).get('hostname') == node['hostname']]
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one Omni machine for {node['hostname']}; found {len(matches)}")
    record = matches[0]
    spec = record['spec']
    if not spec.get('connected') or spec.get('cluster') not in ('', None, 'ictsc-prod'):
        raise SystemExit(f"Machine is disconnected or belongs to another cluster: {node['hostname']}")
    addresses = {str(ipaddress.ip_interface(a).ip) for a in spec['network']['addresses']}
    if not {node['external_ip'], node['internal_ip']} <= addresses:
        raise SystemExit(f"Network identity mismatch: {node['hostname']}")
    nodes[node['hostname']] = {
        'machine_id': record['metadata']['id'], 'role': node['role'],
        'external_ip': node['external_ip'], 'internal_ip': node['internal_ip'],
    }
if len({n['machine_id'] for n in nodes.values()}) != 6:
    raise SystemExit('Duplicate Omni UUIDs')
output = root / '.omni/prod-cluster.tfvars.json'
output.write_text(json.dumps({
    'nodes': nodes, 'external_gateway': expected['external_gateway'],
    'external_prefix': ipaddress.ip_network(expected['external_cidr']).prefixlen,
}, indent=2) + '\n')
output.chmod(0o600)
print(f'Matched six connected prod machines: {output}')
