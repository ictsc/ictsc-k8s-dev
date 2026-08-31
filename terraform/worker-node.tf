resource "sakura_disk" "worker_node" {
  count = local.worker_node_count

  name              = "${local.name}-worker-${count.index + 1}"
  tags              = [var.prefix, local.env, "worker-node"]
  plan              = "ssd"
  connector         = "virtio"
  size              = var.worker_node_disk[local.env]
  source_archive_id = sakura_archive.talos.id

  timeouts = {
    create = "1h"
    delete = "1h"
  }

  # source_archive_id はディスク作成時にしか使われない。にもかかわらず変更すると
  # ディスクごと作り直しになり、etcd も Talos の STATE パーティション
  # (machine config 本体) も消える = クラスタ全損。
  # OS の更新は talosctl upgrade (task upgrade-talos) で行い、Terraform は関与しない。
  # ここを無視することで、var.talos_version を上げても既存ノードは作り直されず、
  # 「これから作る新しいノードだけが新しいアーカイブから作られる」状態になる。
  lifecycle {
    ignore_changes = [source_archive_id]
  }
}

# Longhorn のレプリカデータ専用。OS ディスクと障害・容量を分離する。
# dev のみに作成し、worker へ2本目の virtio ディスクとして接続する。
resource "sakura_disk" "longhorn" {
  count = local.longhorn_enabled ? local.worker_node_count : 0

  name      = "${local.name}-worker-${count.index + 1}-longhorn"
  tags      = [var.prefix, local.env, "worker-node", "longhorn"]
  plan      = "ssd"
  connector = "virtio"
  size      = var.longhorn_disk_size[local.env]

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}

resource "sakura_server" "worker_node" {
  count = local.worker_node_count

  name   = "${local.name}-worker-${count.index + 1}"
  tags   = [var.prefix, local.env, "worker-node"]
  core   = var.worker_node_cpu[local.env]
  memory = var.worker_node_mem[local.env]
  disks = concat(
    [sakura_disk.worker_node[count.index].id],
    local.longhorn_enabled ? [sakura_disk.longhorn[count.index].id] : [],
  )

  cdrom_id         = sakura_cdrom.node_config["${local.name}-worker-${count.index + 1}"].id
  interface_driver = "virtio"

  network_interface = [
    {
      upstream         = sakura_internet.k8s_external.vswitch_id
      user_ip_address  = local.worker_node_ips[count.index]
      packet_filter_id = sakura_packet_filter.worker.id
    },
    {
      upstream        = sakura_vswitch.k8s_internal.id
      user_ip_address = local.worker_node_internal_ip[count.index]
    },
  ]

  timeouts = {
    create = "1h"
    update = "1h"
    delete = "1h"
  }
}
