resource "random_password" "omni" {
  length  = 20
  special = false
}

resource "sakura_disk" "omni" {
  name              = local.name
  tags              = [var.prefix, "management", "omni"]
  plan              = "ssd"
  connector         = "virtio"
  size              = var.omni_disk
  source_archive_id = data.sakura_archive.ubuntu.id

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}

resource "sakura_script" "omni_host" {
  name = "${local.name}-host"
  tags = [var.prefix, "management", "omni"]

  content = <<-EOF
    #!/bin/bash
    # @sacloud-once
    # @sacloud-desc Omni用Dockerホストを初期化
    set -eux

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl docker.io docker-compose-v2 certbot gnupg
    systemctl enable --now docker

    install -d -m 0755 /opt/omni
    install -d -m 0700 /var/lib/omni/etcd /var/lib/omni/sqlite /var/lib/omni/gnupg
  EOF
}

resource "sakura_server" "omni" {
  name   = local.name
  tags   = [var.prefix, "management", "omni"]
  core   = var.omni_cpu
  memory = var.omni_mem
  disks  = [sakura_disk.omni.id]

  interface_driver = "virtio"
  network_interface = [
    {
      upstream         = data.sakura_internet.external.vswitch_id
      user_ip_address  = local.omni_ip
      packet_filter_id = sakura_packet_filter.omni.id
    },
  ]

  disk_edit_parameter = {
    hostname   = local.name
    ip_address = local.omni_ip
    gateway    = data.sakura_internet.external.gateway
    netmask    = data.sakura_internet.external.netmask
    ssh_keys   = var.bastion_ssh_public_keys

    password        = random_password.omni.result
    disable_pw_auth = true
    script          = [{ id = sakura_script.omni_host.id }]
  }

  lifecycle {
    precondition {
      condition     = var.omni_ip_index >= 0 && var.omni_ip_index < length(data.sakura_internet.external.ip_addresses)
      error_message = "omni_ip_indexが既存ルータ+スイッチのIP範囲外です"
    }
  }

  timeouts = {
    create = "1h"
    update = "1h"
    delete = "1h"
  }
}
