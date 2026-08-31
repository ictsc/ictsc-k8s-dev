#!/usr/bin/env bash
# terraform output からノードごとの Talos machine config と cidata ISO を生成する。
#
#   usage: gen-config.sh <talos-input.json>
set -euo pipefail

input="${1:?usage: gen-config.sh <talos-input.json>}"

script_dir="$(cd "$(dirname "$0")" && pwd)"
talos_dir="$(cd "${script_dir}/.." && pwd)"
patch_dir="${talos_dir}/patches"
secrets="${talos_dir}/secrets.yaml"

for cmd in talosctl jq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} が必要です" >&2
    exit 1
  fi
done

q() { jq -r "$1" "${input}"; }

cluster_name="$(q '.cluster_name')"
cluster_endpoint="$(q '.cluster_endpoint')"
kubernetes_version="$(q '.kubernetes_version')"
talos_version="$(q '.talos_version')"
api_vip="$(q '.api_vip')"
domain="$(q '.domain')"
external_cidr="$(q '.external_cidr')"
external_gateway="$(q '.external_gateway')"
external_netmask="${external_cidr##*/}"
internal_network="$(q '.internal_network')"
internal_netmask="${internal_network##*/}"
pod_subnet="$(q '.pod_subnet')"
service_subnet="$(q '.service_subnet')"
nameservers="$(q '.nameservers | join(" ")')"

build="${talos_dir}/build/${cluster_name}"
rm -rf "${build}"
mkdir -p "${build}/base" "${build}/patches" "${build}/config" "${build}/iso"

# クラスタの秘密情報は初回のみ生成する。
if [ ! -f "${secrets}" ]; then
  echo "==> ${secrets} を生成 (紛失するとクラスタを触れなくなるので必ずバックアップすること)"
  talosctl gen secrets -o "${secrets}"
fi

# Terraform 由来の動的パッチ
cat >"${build}/patches/all-dynamic.yaml" <<EOF
cluster:
  network:
    podSubnets:
      - ${pod_subnet}
    serviceSubnets:
      - ${service_subnet}
EOF

cat >"${build}/patches/controlplane-dynamic.yaml" <<EOF
cluster:
  apiServer:
    certSANs:
      - ${api_vip}
      - k8s.${domain}
      - 127.0.0.1
  etcd:
    # etcd のピア通信は内部セグメントに閉じる
    advertisedSubnets:
      - ${internal_network}
EOF

# Kubernetes 1.35 で --oidc-* フラグは削除されたため、AuthenticationConfiguration を
# machine.files と extraVolumes で API server に渡す。prefix は RBAC と揃えること。
cat >"${build}/patches/controlplane-oidc.yaml" <<EOF
machine:
  files:
    - path: /var/lib/kubernetes/auth/authentication-config.yaml
      # API server は非 root で読む。秘密情報は含まない。
      permissions: 0o444
      # create は既存ファイルを更新しない。変更時は削除後に apply-config する。
      op: create
      content: |
        apiVersion: apiserver.config.k8s.io/v1
        kind: AuthenticationConfiguration
        jwt:
          - issuer:
              url: https://dex.${domain}
              audiences:
                - kubernetes
            claimMappings:
              username:
                claim: email
                prefix: "oidc:"
              groups:
                claim: groups
                prefix: "oidc:"
cluster:
  apiServer:
    extraArgs:
      authentication-config: /etc/kubernetes/auth/authentication-config.yaml
    extraVolumes:
      - hostPath: /var/lib/kubernetes/auth
        mountPath: /etc/kubernetes/auth
        readonly: true
EOF

# ロールごとのベース config
echo "==> talosctl gen config (${cluster_name} / ${cluster_endpoint})"
talosctl gen config "${cluster_name}" "${cluster_endpoint}" \
  --with-secrets "${secrets}" \
  --talos-version "${talos_version}" \
  --kubernetes-version "${kubernetes_version}" \
  --output-dir "${build}/base" \
  --force \
  --config-patch "@${patch_dir}/all.yaml" \
  --config-patch "@${build}/patches/all-dynamic.yaml" \
  --config-patch-control-plane "@${patch_dir}/controlplane.yaml" \
  --config-patch-control-plane "@${build}/patches/controlplane-dynamic.yaml" \
  --config-patch-control-plane "@${build}/patches/controlplane-oidc.yaml" \
  --config-patch-worker "@${patch_dir}/worker.yaml"

# ノードごとの config と cidata ISO
node_count="$(jq '.nodes | length' "${input}")"
for i in $(seq 0 $((node_count - 1))); do
  hostname="$(jq -r ".nodes[${i}].hostname" "${input}")"
  role="$(jq -r ".nodes[${i}].role" "${input}")"
  external_ip="$(jq -r ".nodes[${i}].external_ip" "${input}")"
  internal_ip="$(jq -r ".nodes[${i}].internal_ip" "${input}")"

  node_patch="${build}/patches/${hostname}.yaml"
  {
    # hostname は下の HostnameConfig だけで指定する。
    echo "machine:"
    echo "  network:"
    echo "    nameservers:"
    for ns in ${nameservers}; do echo "      - ${ns}"; done
    # NIC 名は Talos のバージョンで変わるため、Terraform の接続順に対応する busPath で選ぶ。
    echo "    interfaces:"
    echo "      - deviceSelector:"
    echo "          busPath: \"0000:00:03.0\""
    echo "        addresses:"
    echo "          - ${external_ip}/${external_netmask}"
    echo "        routes:"
    echo "          - network: 0.0.0.0/0"
    echo "            gateway: ${external_gateway}"
    if [ "${role}" = "controlplane" ]; then
      echo "        vip:"
      echo "          ip: ${api_vip}"
    fi
    echo "      - deviceSelector:"
    echo "          busPath: \"0000:00:04.0\""
    echo "        addresses:"
    echo "          - ${internal_ip}/${internal_netmask}"
    echo "  kubelet:"
    # kubelet と etcd は同じ内部サブネットを使う。
    echo "    nodeIP:"
    echo "      validSubnets:"
    echo "        - ${internal_network}"
    # auto と hostname は排他。
    echo "---"
    echo "apiVersion: v1alpha1"
    echo "kind: HostnameConfig"
    echo "auto: \"off\""
    echo "hostname: ${hostname}"
  } >"${node_patch}"

  talosctl machineconfig patch "${build}/base/${role}.yaml" \
    --patch "@${node_patch}" \
    --output "${build}/config/${hostname}.yaml"

  talosctl validate --config "${build}/config/${hostname}.yaml" --mode metal >/dev/null

  cidata="${build}/cidata/${hostname}"
  mkdir -p "${cidata}"
  cp "${build}/config/${hostname}.yaml" "${cidata}/user-data"
  cat >"${cidata}/meta-data" <<EOF
instance-id: ${hostname}
local-hostname: ${hostname}
EOF
  : >"${cidata}/vendor-data"

  "${script_dir}/build-iso.sh" "${cidata}" "${build}/iso/${hostname}.iso"
  echo "==> ${hostname} (${role}) ${external_ip} -> ${build}/iso/${hostname}.iso"
done

# talosctl 用クライアント設定
cp "${build}/base/talosconfig" "${talos_dir}/talosconfig"
talosctl --talosconfig "${talos_dir}/talosconfig" config endpoints \
  $(jq -r '[.nodes[] | select(.role == "controlplane") | .external_ip] | join(" ")' "${input}")

echo
echo "生成完了: ${build}"
echo "  export TALOSCONFIG=${talos_dir}/talosconfig"
