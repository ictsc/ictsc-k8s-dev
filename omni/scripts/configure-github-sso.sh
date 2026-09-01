#!/usr/bin/env bash
set -euo pipefail

IFS= read -r client_id_b64
IFS= read -r client_secret_b64
client_id=$(printf '%s' "${client_id_b64}" | base64 -d)
client_secret=$(printf '%s' "${client_secret_b64}" | base64 -d)

DEX_CLIENT_ID="${client_id}" DEX_CLIENT_SECRET="${client_secret}" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path("/opt/omni/dex.yaml")
text = path.read_text()
marker = "staticClients:\n"
if marker not in text:
    raise SystemExit("staticClients marker not found")

block = f'''connectors:
  - type: github
    id: github
    name: GitHub
    config:
      clientID: {json.dumps(os.environ["DEX_CLIENT_ID"])}
      clientSecret: {json.dumps(os.environ["DEX_CLIENT_SECRET"])}
      redirectURI: https://auth.omni.ictsc.net:5556/callback
      orgs:
        - name: ictsc

'''

start = text.find("connectors:\n")
if start >= 0:
    end = text.find(marker, start)
    if end < 0:
        raise SystemExit("staticClients marker after connectors not found")
    text = text[:start] + block + text[end:]
else:
    text = text.replace(marker, block + marker, 1)

backup = path.with_suffix(".yaml.before-github")
if not backup.exists():
    backup.write_text(path.read_text())
    backup.chmod(0o400)
path.write_text(text)
path.chmod(0o400)
PY

unset client_id client_secret client_id_b64 client_secret_b64
systemctl restart omni.service
systemctl is-active omni.service
