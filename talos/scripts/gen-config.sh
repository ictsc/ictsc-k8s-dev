#!/usr/bin/env bash
# terraform output (talos_input) を入力に、ノードごとの Talos machine config と
# それを載せた cloud-init NoCloud (cidata) ISO を生成する。
#
#   usage: gen-config.sh <talos-input.json>
#
# 出力:
#   talos/secrets.yaml                        クラスタの PKI (gitignore / 要バックアップ)
#   talos/build/<cluster>/config/<host>.yaml  ノードごとの machine config
#   talos/build/<cluster>/iso/<host>.iso      Terraform が CD-ROM として上げる cidata ISO
#   talos/talosconfig                         talosctl 用のクライアント設定
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

########################################
# 1. クラスタの秘密情報 (初回のみ生成)
########################################
if [ ! -f "${secrets}" ]; then
  echo "==> ${secrets} を生成 (紛失するとクラスタを触れなくなるので必ずバックアップすること)"
  talosctl gen secrets -o "${secrets}"
fi

########################################
# 2. Terraform 由来の値を差し込む動的パッチ
########################################
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

########################################
# 3. ロールごとのベース config
########################################
echo "==> talosctl gen config (${cluster_name} / ${cluster_endpoint})"
talosctl gen config "${cluster_name}" "${cluster_endpoint}" \
  --with-secrets "${secrets}" \
  --kubernetes-version "${kubernetes_version}" \
  --output-dir "${build}/base" \
  --force \
  --config-patch "@${patch_dir}/all.yaml" \
  --config-patch "@${build}/patches/all-dynamic.yaml" \
  --config-patch-control-plane "@${patch_dir}/controlplane.yaml" \
  --config-patch-control-plane "@${build}/patches/controlplane-dynamic.yaml" \
  --config-patch-worker "@${patch_dir}/worker.yaml"

########################################
# 4. ノードごとの config + cidata ISO
########################################
node_count="$(jq '.nodes | length' "${input}")"
for i in $(seq 0 $((node_count - 1))); do
  hostname="$(jq -r ".nodes[${i}].hostname" "${input}")"
  role="$(jq -r ".nodes[${i}].role" "${input}")"
  external_ip="$(jq -r ".nodes[${i}].external_ip" "${input}")"
  internal_ip="$(jq -r ".nodes[${i}].internal_ip" "${input}")"

  node_patch="${build}/patches/${hostname}.yaml"
  {
    # hostname は machine.network.hostname ではなく HostnameConfig ドキュメント側で
    # 指定する (下部参照)。両方に書くと
    #   "static hostname is already set in v1alpha1 config"
    # でバリデーションに落ち、Talos が config を丸ごと捨てて maintenance mode に留まる。
    echo "machine:"
    echo "  network:"
    echo "    nameservers:"
    for ns in ${nameservers}; do echo "      - ${ns}"; done
    echo "    interfaces:"
    echo "      - interface: eth0"
    echo "        addresses:"
    echo "          - ${external_ip}/${external_netmask}"
    echo "        routes:"
    echo "          - network: 0.0.0.0/0"
    echo "            gateway: ${external_gateway}"
    if [ "${role}" = "controlplane" ]; then
      # Talos 組み込みの shared VIP。leader の control plane が ARP を打つ
      echo "        vip:"
      echo "          ip: ${api_vip}"
    fi
    echo "      - interface: eth1"
    echo "        addresses:"
    echo "          - ${internal_ip}/${internal_netmask}"
    echo "  kubelet:"
    # Node の InternalIP は内部セグメントから採る。etcd の advertisedSubnets と
    # 揃えないと talosctl health が通らない。health は etcd メンバー IP と
    # k8s Node IP の両方を同じノードリストと突き合わせるので、片方が外部 IP だと
    # どちらの IP リストを渡しても必ず片方が落ちる。クラスタ内通信も内部側に閉じる。
    echo "    nodeIP:"
    echo "      validSubnets:"
    echo "        - ${internal_network}"
    # talosctl gen config が吐く HostnameConfig (既定は auto: stable) を
    # ノード名で上書きする。auto と hostname は排他なので auto を off にする。
    echo "---"
    echo "apiVersion: v1alpha1"
    echo "kind: HostnameConfig"
    echo "auto: \"off\""
    echo "hostname: ${hostname}"
  } >"${node_patch}"

  talosctl machineconfig patch "${build}/base/${role}.yaml" \
    --patch "@${node_patch}" \
    --output "${build}/config/${hostname}.yaml"

  # 不正な config を焼くと Talos が黙って捨てて maintenance mode に留まり、
  # ネットワークが上がらないので原因究明が非常に困難になる。ここで必ず落とす。
  talosctl validate --config "${build}/config/${hostname}.yaml" --mode metal >/dev/null

  # cidata (NoCloud) ISO
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

########################################
# 5. talosctl 用のクライアント設定
########################################
cp "${build}/base/talosconfig" "${talos_dir}/talosconfig"
talosctl --talosconfig "${talos_dir}/talosconfig" config endpoint \
  $(jq -r '.nodes[] | select(.role == "controlplane") | .external_ip' "${input}")

echo
echo "生成完了: ${build}"
echo "  export TALOSCONFIG=${talos_dir}/talosconfig"
