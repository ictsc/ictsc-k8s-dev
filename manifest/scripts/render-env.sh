#!/usr/bin/env bash
# terraform output 由来の env 固有の値 (VIP・ドメイン) をマニフェストに流し込む。
# Taskfile の render-env-values から呼ばれる。
#
#   usage: render-env.sh <env> <cluster> <domain> <ingress-vip> <acme-email> <pod-subnet>
set -euo pipefail

env="${1:?usage: render-env.sh <env> <cluster> <domain> <ingress-vip> <acme-email> <pod-subnet>}"
cluster="${2:?cluster is required}"
domain="${3:?domain is required}"
vip="${4:?ingress vip is required}"
acme_email="${5:?acme email is required}"
pod_subnet="${6:?pod subnet is required}"

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

# prod と dev で Cilium のクラスタ ID を分ける
cluster_id=1
[ "${env}" = "prod" ] && cluster_id=2

########################################
# Helm values
########################################
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
    # clientSecret は argocd-oidc Secret から読む (Git には置かない)
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
    # false だと Gateway からの平文リクエストに 307 を返し続けてループする
    server.insecure: true

server:
  service:
    # VIP は Gateway が持つ
    type: ClusterIP
EOF

cat > "${d}/values/oauth2-proxy.yaml" <<EOF
${gen}
extraArgs:
  oidc-issuer-url: https://dex.${domain}
  # redirect-url は固定しない。oauth2-proxy は戻り先を相対パスでしか保持せず、
  # callback を別ホストに置くとログイン後に元のアプリへ戻れない
  cookie-domain: .${domain}
  whitelist-domain: .${domain}
  # X-Forwarded-* を信用する送信元を Gateway (Envoy) が居る Pod CIDR に限定する。
  # 未設定だと全 IP からの詐称を受け入れる
  trusted-proxy-ip: ${pod_subnet}
EOF

# 保護対象を増やすときは staticClients の redirectURIs に1行足すだけでよい。
# GitHub 側に登録する callback は Dex の1本だけで固定。
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
        # ここを通過できる GitHub organization
        orgs:
          - name: ictsc

  staticClients:
    - id: oauth2-proxy
      name: oauth2-proxy
      secretEnv: OAUTH2_PROXY_CLIENT_SECRET
      # 保護対象アプリを増やしたらここに <host>/oauth2/callback を足す
      redirectURIs:
        - https://httpbin.${domain}/oauth2/callback
    - id: argocd
      name: Argo CD
      secretEnv: ARGOCD_CLIENT_SECRET
      redirectURIs:
        - https://argocd.${domain}/auth/callback
    # kubectl (kubelogin) 用。CLI にクライアントシークレットは隠せないので
    # public client にして PKCE で守る。redirectURI は kubelogin が
    # ローカルに立てる一時サーバ。既定のポートを両方書いておく。
    - id: kubernetes
      name: Kubernetes
      public: true
      redirectURIs:
        - http://localhost:8000
        - http://localhost:18000
        - http://127.0.0.1:8000
        - http://127.0.0.1:18000
EOF

########################################
# クラスタリソース
########################################
cat > "${d}/resources/cilium-lb-ip-pool.yaml" <<EOF
# LoadBalancer Service に払い出すグローバルIPのプール
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
#
# Ingress VIP はこの Gateway が保持し、振り分けは HTTPRoute で行う。
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
    # cert-manager が ACME チャレンジ用の HTTPRoute をここに生やすので必須
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
    # Gateway と同じ wave に置く。Gateway の HTTPS listener はこの Certificate が作る
    # Secret external-tls を要求し、逆にこの Certificate の HTTP-01 チャレンジは
    # Gateway が無いと解けないという相互依存になっている。別々の wave に分けると
    # Argo CD が Gateway の Healthy を待って次の wave に進まず、
    # "Listener: Invalid CertificateRef" のまま永久に止まる。
    argocd.argoproj.io/sync-wave: "-15"
    # cert-manager の CRD は Argo CD が同期を始める時点ではまだ無い
    # (cert-manager 自体が wave -20 の Application として入る)。
    # Argo CD は実行前に全タスクを dry-run 検証するため、これが無いと
    # "failed to discover server resources for group version cert-manager.io/v1"
    # で同期プランごと却下され、cert-manager が永久に入らないデッドロックになる。
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  secretName: external-tls
  issuerRef:
    name: letsencrypt
    kind: ClusterIssuer
  # HTTP-01 ではワイルドカードが取れないのでホストを列挙する
  dnsNames:
    - argocd.${domain}
    - dex.${domain}
    - httpbin.${domain}
EOF

cat > "${d}/resources/cluster-issuer.yaml" <<EOF
${gen}
#
# HTTP-01 を Gateway API の HTTPRoute で解く。cert-manager は Gateway を
# 書き換えず、チャレンジ中だけ一時的な HTTPRoute を生やす。
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
  annotations:
    # Certificate より先に居ればよい。ACME アカウント登録に Gateway は不要なので
    # Gateway (-15) より前の wave に置く。
    argocd.argoproj.io/sync-wave: "-16"
    # cert-manager の CRD は Argo CD が同期を始める時点ではまだ無い
    # (cert-manager 自体が wave -20 の Application として入る)。
    # Argo CD は実行前に全タスクを dry-run 検証するため、これが無いと
    # "failed to discover server resources for group version cert-manager.io/v1"
    # で同期プランごと却下され、cert-manager が永久に入らないデッドロックになる。
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

cat > "${d}/resources/rbac-oidc.yaml" <<EOF
${gen}
#
# Dex 経由で入ってきた GitHub ユーザに権限を渡す。
# groups / username の prefix "oidc:" は control plane の
# AuthenticationConfiguration (talos/scripts/gen-config.sh) と揃えること。
#
# Dex の github connector は orgs に teams を書いていないとき、groups claim を
# organization 名だけにする。つまり "oidc:ictsc" = ictsc org のメンバー全員。
# team 単位に絞りたくなったら dex の orgs に teams を足し、ここを
# "oidc:ictsc:<team>" に変える。
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-ictsc-cluster-admin
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
subjects:
  - kind: Group
    name: "oidc:ictsc"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

cat > "${d}/resources/httproutes.yaml" <<EOF
${gen}
#
# HTTPRoute は backendRef と同じ namespace に置く (別なら ReferenceGrant が要る)。
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
# 認証を持たない httpbin を ExternalAuth で保護する。
# sync-wave を遅らせるのは、認可バックエンドの Service が無い状態でこの Route が
# 生えると Cilium が ext_authz フィルタを組まず素通しになるため。
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
    # OAuth のやり取りは保護対象から外し、このホスト自身で完結させる
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
              # Cookie が無いとログイン済み判定ができない
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
EOF

echo "==> ${d} を更新しました。git に commit / push してから Argo CD に同期させてください"
