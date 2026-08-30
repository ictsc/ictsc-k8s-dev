resource "sakura_disk" "control_plane" {
  count = local.control_plane_count

  name              = "${local.name}-cp-${count.index + 1}"
  tags              = [var.prefix, local.env, "control-plane"]
  plan              = "ssd"
  connector         = "virtio"
  size              = var.control_plane_disk[local.env]
  source_archive_id = sakura_archive.talos.id

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}

resource "sakura_server" "control_plane" {
  count = local.control_plane_count

  name   = "${local.name}-cp-${count.index + 1}"
  tags   = [var.prefix, local.env, "control-plane"]
  core   = var.control_plane_cpu[local.env]
  memory = var.control_plane_mem[local.env]
  disks  = [sakura_disk.control_plane[count.index].id]

  # Talos はさくらのクラウドのディスク修正 (disk_edit_parameter) に対応しないので、
  # 設定は cidata の CD-ROM 経由で渡す
  cdrom_id         = sakura_cdrom.node_config["${local.name}-cp-${count.index + 1}"].id
  interface_driver = "virtio"

  network_interface = [
    {
      # eth0: グローバル (API VIP / Ingress の L2 もここ)
      upstream         = sakura_internet.k8s_external.vswitch_id
      user_ip_address  = local.control_plane_ips[count.index]
      packet_filter_id = sakura_packet_filter.control_plane.id
    },
    {
      # eth1: 内部セグメント (etcd ピア通信)
      upstream        = sakura_vswitch.k8s_internal.id
      user_ip_address = local.control_plane_internal_ip[count.index]
    },
  ]

  timeouts = {
    create = "1h"
    update = "1h"
    delete = "1h"
  }
}
