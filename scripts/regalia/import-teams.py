#!/usr/bin/env python3
"""Idempotently register configured teams via the admin API; never overwrite mismatches."""
import getpass
import json
from pathlib import Path
import urllib.request
import yaml

root = Path(__file__).resolve().parents[2]
teams = yaml.safe_load((root / 'config/regalia/dev-discord-teams.yaml').read_text())['teams']
origin = 'https://contest.k8s-dev.ictsc.net'
token = getpass.getpass('admin-session cookie value (not saved): ')
def request(method, path, data=None):
    req = urllib.request.Request(origin + path, method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={'Cookie': 'admin-session=' + token, 'Origin': origin, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)
existing = {t['code']: t for t in request('GET', '/api/v1/admin/teams')['teams']}
for team in teams:
    body = {key: team[key] for key in ('code', 'name', 'organization', 'member_limit')}
    if team['code'] in existing:
        if any(existing[team['code']][key] != value for key, value in body.items()):
            raise SystemExit(f"Existing team {team['code']} differs; review in admin UI")
        continue
    request('POST', '/api/v1/admin/teams', body)
actual = {t['code']: t for t in request('GET', '/api/v1/admin/teams')['teams']}
assert all(actual[t['code']]['name'] == t['name'] for t in teams)
print(f'Verified {len(teams)} teams')
