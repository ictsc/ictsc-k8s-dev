#!/usr/bin/env bash
# Scope Sakura credentials and workspace to one Terraform invocation.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:?usage: terraform-env.sh dev|prod <terraform arguments>}"
shift
case "$target" in dev|prod) ;; *) echo 'ENV must be dev or prod' >&2; exit 2 ;; esac
if [ "$#" -eq 0 ]; then
  echo 'Terraform arguments are required (e.g. -- plan)' >&2
  exit 2
fi
credential_file="$root/.omni/$target-sakura.env"
if [ ! -f "$credential_file" ]; then
  echo "Missing credentials: $credential_file" >&2
  exit 1
fi
# Do not inherit the other environment's key if the file is incomplete.
unset SAKURACLOUD_ACCESS_TOKEN SAKURACLOUD_ACCESS_TOKEN_SECRET
source "$credential_file"
: "${SAKURACLOUD_ACCESS_TOKEN:?Missing access token}"
: "${SAKURACLOUD_ACCESS_TOKEN_SECRET:?Missing access token secret}"
export SAKURACLOUD_ACCESS_TOKEN SAKURACLOUD_ACCESS_TOKEN_SECRET
export TF_WORKSPACE="$target"
if [ "$target" = prod ]; then
  export TF_VAR_talos_version=v1.13.9
fi
# Backend AWS_* credentials are intentionally unchanged.
python3 - "$root/config/sakura-projects.json" "$target" <<'PY'
import base64
import json
import os
import sys
import urllib.request

expected = json.load(open(sys.argv[1]))[sys.argv[2]]
token = os.environ['SAKURACLOUD_ACCESS_TOKEN']
secret = os.environ['SAKURACLOUD_ACCESS_TOKEN_SECRET']
authorization = base64.b64encode(f'{token}:{secret}'.encode()).decode()
zone = os.environ.get('SAKURACLOUD_ZONE', 'tk1a')
if zone not in ('tk1a', 'tk1b', 'is1a', 'is1b', 'is1c'):
    raise SystemExit('Unsupported Sakura zone: ' + zone)
request = urllib.request.Request(
    f'https://secure.sakura.ad.jp/cloud/zone/{zone}/api/cloud/1.1/auth-status',
    headers={'Authorization': 'Basic ' + authorization},
)
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        account = json.load(response)['Account']
except Exception as error:
    raise SystemExit('Sakura project verification failed: ' + str(error))
if str(account['ID']) != expected['id']:
    raise SystemExit('Sakura project mismatch; refusing to run Terraform')
print(f"Terraform: {sys.argv[2]} / {account['Name']} / {zone}", file=sys.stderr)
PY
exec terraform -chdir="$root/terraform" "$@"
