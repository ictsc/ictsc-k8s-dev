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

# kubectl の GitHub SSO (Dex 経由の OIDC)。
#
# Kubernetes 1.35 で --oidc-* フラグは削除されたため、AuthenticationConfiguration を
# ファイルで渡す。Talos v1.13 には専用フィールドが無い (authConfig /
# authenticationConfig はどちらも unknown key) ので、machine.files でファイルを置き、
# extraVolumes で apiserver に読ませる。
#
# Dex の証明書は Let's Encrypt なので certificateAuthority は不要 (システムCAを使う)。
# username / groups の prefix は manifest 側の ClusterRoleBinding と揃えること。
cat >"${build}/patches/controlplane-oidc.yaml" <<EOF
machine:
  files:
    - path: /var/lib/kubernetes/auth/authentication-config.yaml
      # apiserver は非 root (UID 65534) で動くので 0o400 だと読めず、
      # コンテナが exit 1 で crashloop する。issuer URL と claim 名しか
      # 入っていない (秘密情報なし) ので 0o444 でよい。
      permissions: 0o444
      # overwrite は「既にあるファイルを上書き」なので、ファイルが無い初回は
      #   file must exist: "/var/lib/kubernetes/auth/authentication-config.yaml"
      # で writeUserFiles ごと失敗し、kubelet も etcd も起動しなくなる。
      # create は「無ければ作る / あれば何もしない」なのでこちらを使う。
      # NOTE: create のため、この中身を変えても既存ノードには反映されない。
      #       変更するときは talosctl でファイルを消してから apply-config すること。
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

########################################
# 3. ロールごとのベース config
########################################
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
    # インターフェースは名前ではなく PCI バスパスで選ぶ。
    #
    # Talos v1.13.9 でリンク名の既定が eth0/eth1 から ens3/ens4 に変わった。
    # 名前で書いていると、OS を上げた瞬間にどのリンクにもマッチしなくなり、
    # 静的 IP が一切適用されないまま DHCP にフォールバックする
    # (グローバル側はアドレス無し = 到達不能、内部側は踏み台の DHCP レンジを掴む)。
    # config 自体は入っているので apid は動くが、API VIP も kubelet も上がらない。
    #
    # バスパスは NIC の接続順で決まり、Terraform の network_interface の順序
    # (0 = グローバル / 1 = 内部) と一致する。名前と違って Talos のバージョンでは
    # 変わらないので、こちらを使う。MAC でも選べるが、MAC はサーバ作成後にしか
    # 分からず、ISO を先に焼くこの構成では使えない。
    echo "    interfaces:"
    echo "      - deviceSelector:"
    echo "          busPath: \"0000:00:03.0\""
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
    echo "      - deviceSelector:"
    echo "          busPath: \"0000:00:04.0\""
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
talosctl --talosconfig "${talos_dir}/talosconfig" config endpoints \
  $(jq -r '[.nodes[] | select(.role == "controlplane") | .external_ip] | join(" ")' "${input}")

echo
echo "生成完了: ${build}"
echo "  export TALOSCONFIG=${talos_dir}/talosconfig"
