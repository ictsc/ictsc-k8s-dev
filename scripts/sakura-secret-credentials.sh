#!/usr/bin/env bash
# 認証情報は環境変数から読み、標準入力で kubectl に渡す。
set +x
set -euo pipefail

for name in SAKURA_SECRETS_ACCESS_TOKEN SAKURA_SECRETS_ACCESS_TOKEN_SECRET SAKURA_SECRETS_VAULT_ID SECRET_KUBE_CONTEXT; do
  if [[ -z "${!name:-}" ]]; then
    printf 'Required environment variable: %s\n' "$name" >&2
    exit 1
  fi
done

for command in jq kubectl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command: %s\n' "$command" >&2
    exit 1
  fi
done

export SECRET_NAMESPACE="${SECRET_NAMESPACE:-external-secrets}"
kubectl_args=(--context "$SECRET_KUBE_CONTEXT" -n "$SECRET_NAMESPACE")
kubectl "${kubectl_args[@]}" get namespace "$SECRET_NAMESPACE" >/dev/null

# jq の env で読むことで、値をプロセス引数や一時ファイルに載せない。
# server-side apply は last-applied-configuration に値のコピーを保存しない。
# API エラーに Secret 本文が含まれる場合に備え、失敗時は固定メッセージを出す。
if ! jq -n '{
  apiVersion: "v1",
  kind: "Secret",
  metadata: {
    name: "sakura-secret-manager-credentials",
    namespace: env.SECRET_NAMESPACE,
    labels: {"external-secrets.io/type": "webhook"}
  },
  type: "Opaque",
  stringData: {
    token: env.SAKURA_SECRETS_ACCESS_TOKEN,
    secret: env.SAKURA_SECRETS_ACCESS_TOKEN_SECRET,
    vaultID: env.SAKURA_SECRETS_VAULT_ID
  }
}' 2>/dev/null | kubectl "${kubectl_args[@]}" apply --server-side \
    --field-manager=sakura-secret-bootstrap -f - >/dev/null 2>&1; then
  printf 'Failed to configure credentials; check Kubernetes access and Secret write permissions.\n' >&2
  exit 1
fi

printf '%s/sakura-secret-manager-credentials configured\n' "$SECRET_NAMESPACE"
