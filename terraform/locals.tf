locals {
  # 各変数は dev / prod のキーしか持たないため、他の workspace だと
  # lookup が既定値に落ちてノード0台の空っぽな plan が出てしまう。明示的に落とす。
  valid_workspace = contains(["dev", "prod"], terraform.workspace) ? true : tobool(
    "terraform workspace が '${terraform.workspace}' です。`task select-dev` か `task select-prod` で dev / prod を選んでください"
  )

  env    = local.valid_workspace ? terraform.workspace : ""
  name   = "${var.prefix}-${local.env}"
  domain = var.domain[local.env]

  control_plane_count = var.control_plane[local.env]
  worker_node_count   = var.worker_node[local.env]
  longhorn_enabled    = var.longhorn_disk_size[local.env] > 0

  external_netmask = var.external_subnet[local.env]
  external_gateway = sakura_internet.k8s_external.gateway
  external_cidr    = "${sakura_internet.k8s_external.network_address}/${local.external_netmask}"

  # sakura_internet.ip_addresses の割り当て方針
  #   [0 .. cp-1]                     : control plane
  #   [cp]                            : Kubernetes API VIP (Talos の shared VIP)
  #   [cp+1]                          : Ingress VIP (Cilium LB IPAM + L2 Announcement)
  #   [cp+2 .. cp+1+worker]           : worker node
  control_plane_ips = slice(sakura_internet.k8s_external.ip_addresses, 0, local.control_plane_count)
  api_vip           = sakura_internet.k8s_external.ip_addresses[local.control_plane_count]
  ingress_vip       = sakura_internet.k8s_external.ip_addresses[local.control_plane_count + 1]
  worker_node_ips = slice(
    sakura_internet.k8s_external.ip_addresses,
    local.control_plane_count + 2,
    local.control_plane_count + 2 + local.worker_node_count,
  )

  # 踏み台はノードの後ろに続けて1個
  bastion_ip = sakura_internet.k8s_external.ip_addresses[local.control_plane_count + 2 + local.worker_node_count]

  # 内部セグメント: control plane は .1 から / worker は .101 から
  # (プレフィクス長は talos/scripts/gen-config.sh が internal_network から切り出す)
  control_plane_internal_ip = [for i in range(local.control_plane_count) : cidrhost(var.internal_network, i + 1)]
  worker_node_internal_ip   = [for i in range(local.worker_node_count) : cidrhost(var.internal_network, i + 101)]

  internal_netmask = split("/", var.internal_network)[1]

  # 踏み台は内部セグメントの末尾。DHCP は .200-.250 から配る
  # (ノードの静的IPは .1-.x / .101-.x なので重ならない)
  # NFS アプライアンス。ノード (.1-, .101-) とも DHCP レンジ (.200-.250) とも
  # 踏み台 (.254) とも重ならない位置に置く。
  nfs_internal_ip = cidrhost(var.internal_network, 150)

  bastion_internal_ip = cidrhost(var.internal_network, 254)
  bastion_dhcp_start  = cidrhost(var.internal_network, 200)
  bastion_dhcp_end    = cidrhost(var.internal_network, 250)

  cluster_endpoint = "https://${local.api_vip}:6443"

  # Talos の machine config 生成スクリプトに渡す入力
  talos_input = {
    cluster_name       = local.name
    cluster_endpoint   = local.cluster_endpoint
    talos_version      = var.talos_version
    kubernetes_version = var.kubernetes_version

    api_vip     = local.api_vip
    ingress_vip = local.ingress_vip
    domain      = local.domain

    external_cidr    = local.external_cidr
    external_gateway = local.external_gateway
    internal_network = var.internal_network
    nameservers      = var.nameservers

    pod_subnet     = var.pod_subnet
    service_subnet = var.service_subnet

    nodes = concat(
      [for i in range(local.control_plane_count) : {
        hostname    = "${local.name}-cp-${i + 1}"
        role        = "controlplane"
        external_ip = local.control_plane_ips[i]
        internal_ip = local.control_plane_internal_ip[i]
      }],
      [for i in range(local.worker_node_count) : {
        hostname    = "${local.name}-worker-${i + 1}"
        role        = "worker"
        external_ip = local.worker_node_ips[i]
        internal_ip = local.worker_node_internal_ip[i]
      }],
    )
  }
}
