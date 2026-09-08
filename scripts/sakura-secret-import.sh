#!/usr/bin/env bash
# ESO の CRD 導入後、values の対応表に従い既存値を保管庫へコピーする。
set +x
set -euo pipefail
for name in SECRET_KUBE_CONTEXT SAKURA_SECRETS_VAULT_ID SAKURACLOUD_ACCESS_TOKEN SAKURACLOUD_ACCESS_TOKEN_SECRET; do
  if [[ -z "${!name:-}" ]]; then
    printf 'Required environment variable: %s\n' "$name" >&2
    exit 1
  fi
done
if [[ $# != 2 ]]; then
  printf 'Usage: bash scripts/sakura-secret-import.sh NAMESPACE VALUES_FILE\n' >&2
  exit 1
fi
namespace=$1
values_file=$2
[[ "$SAKURA_SECRETS_VAULT_ID" =~ ^[0-9]+$ ]] || { echo 'Invalid vault ID' >&2; exit 1; }
script_root=$(cd "$(dirname "$0")/.." && pwd)
kubectl_args=(--context "$SECRET_KUBE_CONTEXT" -n "$namespace")
api="https://secure.sakura.ad.jp/cloud/zone/is1a/api/cloud/1.1/secretmanager/vaults/${SAKURA_SECRETS_VAULT_ID}/secrets"

# Basic 認証は匿名パイプから読み、値は引数・ファイル・ログに出さない。
call_api() {
  curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
    --config <(jq -nr '
      (env.SAKURACLOUD_ACCESS_TOKEN + ":" + env.SAKURACLOUD_ACCESS_TOKEN_SECRET | @base64)
      | "header = \"Authorization: Basic " + . + "\""') \
    -H 'Content-Type: application/json' "$@" 2>/dev/null
}

# client dry-run で YAML を JSON 化する。ESO CRD の discovery が必要。
mappings=$(helm template secret-import "$script_root/charts/sakura-secrets" \
  --namespace "$namespace" -f "$values_file" --set enabled=true \
  | kubectl "${kubectl_args[@]}" create --dry-run=client --validate=false -f - -o json \
  | jq -sr '[.[] | if .kind == "List" then .items[] else . end
      | select(.kind == "ExternalSecret")
      | . as $es | .spec.data[] | [$es.spec.target.name, .secretKey, .remoteRef.key]]')
[[ "$(printf '%s' "$mappings" | jq length)" != 0 ]] || { echo 'No mappings found' >&2; exit 1; }
existing=$(call_api "$api?Count=100&From=0") || { echo 'Cannot list Sakura secrets' >&2; exit 1; }
printf '%s' "$existing" | jq -e '(.Secrets | type == "array") and (.Total == (.Secrets | length))' >/dev/null \
  || { echo 'Incomplete remote secret list; import stopped' >&2; exit 1; }

while IFS=$'\t' read -r secret_name key remote; do
  # 値は JSON のまま保持し、末尾改行も保存する。
  payload=$(kubectl "${kubectl_args[@]}" get secret "$secret_name" -o json \
    | jq -ce --arg key "$key" --arg remote "$remote" '
        if .data[$key] == null then error("missing source key")
        else {Secret: {Name: $remote, Value: (.data[$key] | @base64d)}} end')
  if printf '%s' "$existing" | jq -e --arg name "$remote" 'any(.Secrets[]; .Name == $name)' >/dev/null; then
    current=$(printf '%s' "$payload" | jq '{Secret: {Name: .Secret.Name}}' \
      | call_api -X POST --data-binary @- "$api/unveil") || { echo 'Cannot read existing remote secret' >&2; exit 1; }
    if ! { printf '%s\n' "$payload"; printf '%s\n' "$current"; } \
      | jq -se '.[0].Secret.Value == .[1].Secret.Value' >/dev/null; then
      printf 'Existing remote value differs: %s (not overwritten)\n' "$remote" >&2
      exit 1
    fi
    printf 'Already matches: %s\n' "$remote"
  else
    printf '%s' "$payload" | call_api -X POST --data-binary @- "$api" >/dev/null \
      || { printf 'Import failed: %s\n' "$remote" >&2; exit 1; }
    existing=$(printf '%s' "$existing" | jq --arg name "$remote" '.Secrets += [{Name: $name}]')
    printf 'Imported: %s/%s -> %s\n' "$secret_name" "$key" "$remote"
  fi
done < <(printf '%s' "$mappings" | jq -r '.[] | @tsv')
