#!/usr/bin/env bash
# terraform output 由来の値を環境別マニフェストに反映する。
#   usage: render-env.sh <env> <cluster> <domain> <ingress-vip> <acme-email> <pod-subnet> <nfs-ip>
set -euo pipefail

env="${1:?usage: render-env.sh <env> <cluster> <domain> <ingress-vip> <acme-email> <pod-subnet> <nfs-ip>}"
cluster="${2:?cluster is required}"
domain="${3:?domain is required}"
vip="${4:?ingress vip is required}"
acme_email="${5:?acme email is required}"
pod_subnet="${6:?pod subnet is required}"
nfs_ip="${7:?nfs ip is required}"

case "${acme_email}" in
  TODO-*)
    echo "ERROR: ACME_EMAIL が未設定です。Let's Encrypt の登録に使うアドレスを指定してください" >&2
    echo "  例: ACME_EMAIL=admin@k1h.dev task render-env-values" >&2
    exit 1
    ;;
esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
d="$(cd "${script_dir}/../envs/${env}" && pwd)"
gen="# このファイルは \`task render-env-values\` が terraform output から生成する"

cluster_id=1
[ "${env}" = "prod" ] && cluster_id=2

regalia_oauth2_redirect_uris=""
longhorn_oauth2_redirect_uri=""
longhorn_certificate_dns_name=""
longhorn_httproute=""
if [ "${env}" = "dev" ]; then
  regalia_oauth2_redirect_uris="        - https://contest.${domain}/oauth2/callback
        - https://admin-contest.${domain}/oauth2/callback"
  longhorn_oauth2_redirect_uri="        - https://longhorn.${domain}/oauth2/callback"
  longhorn_certificate_dns_name="    - longhorn.${domain}"
  longhorn_httproute="---
# Longhorn UI は認証機能を持たないため ExternalAuth で保護する。
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: longhorn
  namespace: longhorn-system
  annotations:
    argocd.argoproj.io/sync-wave: \"10\"
spec:
  parentRefs:
    - name: external
      namespace: gateway
      sectionName: https
  hostnames:
    - longhorn.${domain}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /oauth2
      backendRefs:
        - name: oauth2-proxy
          namespace: oauth2-proxy
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: ExternalAuth
          externalAuth:
            protocol: HTTP
            backendRef:
              kind: Service
              name: oauth2-proxy
              namespace: oauth2-proxy
              port: 80
            http:
              allowedHeaders:
                - Cookie
                - X-Forwarded-Proto
                - X-Forwarded-Host
              allowedResponseHeaders:
                - Set-Cookie
                - X-Auth-Request-User
                - X-Auth-Request-Email
      backendRefs:
        - name: longhorn-frontend
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: longhorn-to-oauth2-proxy
  namespace: oauth2-proxy
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: longhorn-system
  to:
    - group: \"\"
      kind: Service
      name: oauth2-proxy"
fi

# Helm values
cat > "${d}/values/cilium.yaml" <<EOF
${gen}
cluster:
  name: ${cluster}
  id: ${cluster_id}
EOF

cat > "${d}/values/argocd.yaml" <<EOF
${gen}
global:
  domain: argocd.${domain}

configs:
  cm:
    oidc.config: |
      name: Dex
      issuer: https://dex.${domain}
      clientID: argocd
      clientSecret: \$argocd-oidc:clientSecret
      requestedScopes:
        - openid
        - profile
        - email
        - groups
  params:
    # Gateway との TLS 終端後のリダイレクトループを防ぐ。
    server.insecure: true

server:
  service:
    type: ClusterIP
EOF

cat > "${d}/values/kube-prometheus-stack.yaml" <<EOF
${gen}
grafana:
  envValueFrom:
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:
      secretKeyRef:
        name: grafana-oidc
        key: clientSecret
  grafana.ini:
    server:
      domain: grafana.${domain}
      root_url: https://grafana.${domain}
    auth:
      disable_login_form: false
      oauth_auto_login: false
    auth.generic_oauth:
      enabled: true
      name: GitHub (Dex)
      client_id: grafana
      scopes: openid profile email groups
      auth_url: https://dex.${domain}/auth
      token_url: https://dex.${domain}/token
      api_url: https://dex.${domain}/userinfo
      # Dex の groups は "<org>:<team>" 形式。
      role_attribute_path: contains(groups[*], 'ictsc:ictsc2026') && 'Admin' || 'Viewer'
      allow_assign_grafana_admin: true
EOF

cat > "${d}/values/oauth2-proxy.yaml" <<EOF
${gen}
extraArgs:
  oidc-issuer-url: https://dex.${domain}
  # callback を保護対象の各ホストで完結させるため redirect-url は固定しない。
  cookie-domain: .${domain}
  whitelist-domain: .${domain}
  # X-Forwarded-* を信用する送信元を Gateway の Pod CIDR に限定する。
  trusted-proxy-ip: ${pod_subnet}
EOF

cat > "${d}/values/dex.yaml" <<EOF
${gen}
config:
  issuer: https://dex.${domain}

  storage:
    type: kubernetes
    config:
      inCluster: true

  oauth2:
    skipApprovalScreen: true

  connectors:
    - type: github
      id: github
      name: GitHub
      config:
        clientID: \$GITHUB_CLIENT_ID
        clientSecret: \$GITHUB_CLIENT_SECRET
        redirectURI: https://dex.${domain}/callback
        orgs:
          - name: ictsc

  staticClients:
    - id: oauth2-proxy
      name: oauth2-proxy
      secretEnv: OAUTH2_PROXY_CLIENT_SECRET
      redirectURIs:
        - https://httpbin.${domain}/oauth2/callback
${regalia_oauth2_redirect_uris}
${longhorn_oauth2_redirect_uri}
    - id: argocd
      name: Argo CD
      secretEnv: ARGOCD_CLIENT_SECRET
      redirectURIs:
        - https://argocd.${domain}/auth/callback
    - id: grafana
      name: Grafana
      secretEnv: GRAFANA_CLIENT_SECRET
      redirectURIs:
        - https://grafana.${domain}/login/generic_oauth
    # kubelogin は public client + PKCE を使う。
    - id: kubernetes
      name: Kubernetes
      public: true
      redirectURIs:
        - http://localhost:8000
        - http://localhost:18000
        - http://127.0.0.1:8000
        - http://127.0.0.1:18000
EOF

# クラスタリソース
cat > "${d}/resources/cilium-lb-ip-pool.yaml" <<EOF
${gen}
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: external
  annotations:
    argocd.argoproj.io/sync-wave: "-25"
spec:
  blocks:
    - start: ${vip}
      stop: ${vip}
EOF

cat > "${d}/resources/gateway.yaml" <<EOF
${gen}
apiVersion: v1
kind: Namespace
metadata:
  name: gateway
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external
  namespace: gateway
  annotations:
    argocd.argoproj.io/sync-wave: "-15"
spec:
  gatewayClassName: cilium
  addresses:
    - type: IPAddress
      value: "${vip}"
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.${domain}"
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.${domain}"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: external-tls
      allowedRoutes:
        namespaces:
          from: All
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: external
  namespace: gateway
  annotations:
    # Gateway と Certificate は相互依存するため同じ wave に置く。
    argocd.argoproj.io/sync-wave: "-15"
    # cert-manager の CRD は wave -20 で作られる。
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  secretName: external-tls
  issuerRef:
    name: letsencrypt
    kind: ClusterIssuer
  # HTTP-01 はワイルドカード証明書に対応しない。
  dnsNames:
    - argocd.${domain}
    - dex.${domain}
    - httpbin.${domain}
    - grafana.${domain}
${longhorn_certificate_dns_name}
    - contest.${domain}
    - admin-contest.${domain}
EOF

cat > "${d}/resources/cluster-issuer.yaml" <<EOF
${gen}
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
  annotations:
    argocd.argoproj.io/sync-wave: "-16"
    # cert-manager の CRD は wave -20 で作られる。
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${acme_email}
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: external
                namespace: gateway
                kind: Gateway
EOF

cat > "${d}/resources/storageclass-nfs.yaml" <<EOF
${gen}
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.csi.k8s.io
parameters:
  server: ${nfs_ip}
  share: /export
  # subDir を省略すると PV ごとに分離される。NFS では fsGroup が効かない。
  mountPermissions: "0777"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  # さくらの NFS アプライアンスは NFSv4.0 まで。
  - nfsvers=4.0
  - hard
  - noatime
EOF

cat > "${d}/resources/rbac-oidc.yaml" <<EOF
${gen}
# groups / username の prefix "oidc:" は control plane の
# AuthenticationConfiguration (talos/scripts/gen-config.sh) と揃えること。
# Dex の groups は "<org>:<team>" 形式。権限を渡す team を列挙する。
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-ictsc-cluster-admin
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
subjects:
  - kind: Group
    name: "oidc:ictsc:ictsc2026"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

cat > "${d}/resources/httproutes.yaml" <<EOF
${gen}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  parentRefs:
    - name: external
      namespace: gateway
      sectionName: https
  hostnames:
    - argocd.${domain}
  rules:
    - backendRefs:
        - name: argocd-server
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: dex
  namespace: dex
spec:
  parentRefs:
    - name: external
      namespace: gateway
      sectionName: https
  hostnames:
    - dex.${domain}
  rules:
    - backendRefs:
        - name: dex
          port: 5556
---
# 認可 Service より後に作り、httpbin を ExternalAuth で保護する。
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: httpbin
  namespace: httpbin
  annotations:
    argocd.argoproj.io/sync-wave: "10"
spec:
  parentRefs:
    - name: external
      namespace: gateway
      sectionName: https
  hostnames:
    - httpbin.${domain}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /oauth2
      backendRefs:
        - name: oauth2-proxy
          namespace: oauth2-proxy
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: ExternalAuth
          externalAuth:
            protocol: HTTP
            backendRef:
              kind: Service
              name: oauth2-proxy
              namespace: oauth2-proxy
              port: 80
            http:
              allowedHeaders:
                - Cookie
                - X-Forwarded-Proto
                - X-Forwarded-Host
              allowedResponseHeaders:
                - Set-Cookie
                - X-Auth-Request-User
                - X-Auth-Request-Email
      backendRefs:
        - name: httpbin
          port: 8080
---
# Grafana はロール判定に groups を使うため Dex と直接 OIDC 接続する。
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: monitoring
spec:
  parentRefs:
    - name: external
      namespace: gateway
      sectionName: https
  hostnames:
    - grafana.${domain}
  rules:
    - backendRefs:
        - name: kube-prometheus-stack-grafana
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: httpbin-to-oauth2-proxy
  namespace: oauth2-proxy
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: httpbin
  to:
    - group: ""
      kind: Service
      name: oauth2-proxy
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: scoreserver-to-oauth2-proxy
  namespace: oauth2-proxy
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: scoreserver
  to:
    - group: ""
      kind: Service
      name: oauth2-proxy
${longhorn_httproute}
EOF

echo "==> ${d} を更新しました。git に commit / push してから Argo CD に同期させてください"
