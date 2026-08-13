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
}

resource "sakura_server" "worker_node" {
  count = local.worker_node_count

  name   = "${local.name}-worker-${count.index + 1}"
  tags   = [var.prefix, local.env, "worker-node"]
  core   = var.worker_node_cpu[local.env]
  memory = var.worker_node_mem[local.env]
  disks  = [sakura_disk.worker_node[count.index].id]

  cdrom_id         = sakura_cdrom.node_config["${local.name}-worker-${count.index + 1}"].id
  interface_driver = "virtio"

  network_interface = [
    {
      upstream        = sakura_internet.k8s_external.vswitch_id
      user_ip_address = local.worker_node_ips[count.index]
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
