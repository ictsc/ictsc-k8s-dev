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

# prod の Longhorn レプリカデータ専用。dev は 40 GiB のコピー先を使用する。
resource "sakura_disk" "longhorn" {
  count = local.longhorn_enabled && local.env != "dev" ? local.worker_node_count : 0

  name      = "${local.name}-worker-${count.index + 1}-longhorn"
  tags      = [var.prefix, local.env, "worker-node", "longhorn"]
  plan      = "ssd"
  connector = "virtio"
  size      = var.longhorn_disk_size[local.env]

  # dev の旧ディスク削除後、prod の誤削除防止を別変更で復旧する。

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}

# dev worker-1 の 40 GiB Longhorn ディスク。
resource "sakura_disk" "dev_worker1_longhorn_40g" {
  count = local.env == "dev" ? 1 : 0

  name      = "${local.name}-worker-1-longhorn-40g"
  tags      = [var.prefix, local.env, "worker-node", "longhorn"]
  plan      = "ssd"
  connector = "virtio"
  size      = 40

  lifecycle {
    prevent_destroy = true
  }

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}

# dev worker-2/3 の 40 GiB Longhorn ディスク。
resource "sakura_disk" "dev_other_workers_longhorn_40g" {
  count = local.env == "dev" ? 2 : 0

  name      = "${local.name}-worker-${count.index + 2}-longhorn-40g"
  tags      = [var.prefix, local.env, "worker-node", "longhorn"]
  plan      = "ssd"
  connector = "virtio"
  size      = 40

  lifecycle {
    prevent_destroy = true
  }

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
    local.longhorn_enabled ? [
      local.env == "dev" && count.index > 0 ? sakura_disk.dev_other_workers_longhorn_40g[count.index - 1].id : (
        local.env == "dev" && count.index == 0 ? sakura_disk.dev_worker1_longhorn_40g[0].id : sakura_disk.longhorn[count.index].id
      )
    ] : [],
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
