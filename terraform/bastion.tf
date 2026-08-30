# 踏み台サーバ
#
# Talos は さくらのクラウドの「ディスクの修正」(disk_edit_parameter) に対応しないため、
# 起動直後のノードは machine config が入るまでネットワークを持たない。
# ルータ+スイッチには DHCP が無いので、そのままでは maintenance mode のノードに
# 到達する手段が一切ない。
#
# そこで内部セグメント (vSwitch) 側に DHCP を配る踏み台を置き、
#   1. maintenance mode の Talos が eth1 で DHCP アドレスを掴む
#   2. 踏み台から talosctl apply-config --insecure を打つ
# という経路を用意する。
#
# 踏み台自体は Ubuntu なので disk_edit_parameter がそのまま使える (drove と同じ)。

data "sakura_archive" "ubuntu" {
  os_type = "ubuntu2404"
}

# コンソールからログインするためのパスワード。
# SSH のパスワード認証は無効のままなので、用途はコンソールのみ。
#   terraform output -raw bastion_password
resource "random_password" "bastion" {
  length  = 20
  special = false
}

resource "sakura_disk" "bastion" {
  name              = "${local.name}-bastion"
  tags              = [var.prefix, local.env, "bastion"]
  plan              = "ssd"
  connector         = "virtio"
  size              = var.bastion_disk
  source_archive_id = data.sakura_archive.ubuntu.id

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}

# 起動時に dnsmasq を入れて内部セグメントに DHCP を配る
resource "sakura_script" "bastion_dhcp" {
  name = "${local.name}-bastion-dhcp"
  tags = [var.prefix, local.env, "bastion"]

  content = <<-EOF
    #!/bin/bash
    # @sacloud-once
    # @sacloud-desc 内部セグメントに DHCP を配り、talosctl を入れる
    set -eux

    # eth1 (内部セグメント) を静的に設定。
    # eth0 の設定はさくらの「ディスクの修正」が書いたものをそのまま使うので触らない。
    # デフォルトルートを奪わないよう gateway/routes は書かないこと。
    cat >/etc/netplan/60-internal.yaml <<'NETPLAN'
    network:
      version: 2
      ethernets:
        eth1:
          dhcp4: false
          dhcp6: false
          optional: true
          addresses:
            - ${local.bastion_internal_ip}/${local.internal_netmask}
    NETPLAN
    chmod 600 /etc/netplan/60-internal.yaml
    # ここで失敗しても eth0 の疎通と後続のインストールは続行させる
    netplan apply || true

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y dnsmasq

    # 内部セグメントにだけ DHCP を配る。DNS 機能は使わない (port=0)
    cat >/etc/dnsmasq.d/talos.conf <<'DNSMASQ'
    port=0
    interface=eth1
    bind-interfaces
    dhcp-range=${local.bastion_dhcp_start},${local.bastion_dhcp_end},12h
    dhcp-option=option:router,${local.bastion_internal_ip}
    DNSMASQ

    systemctl enable --now dnsmasq
    systemctl restart dnsmasq

    # 踏み台から apply-config を打てるように talosctl を入れる
    curl -fsSL -o /usr/local/bin/talosctl \
      https://github.com/siderolabs/talos/releases/download/${var.talos_version}/talosctl-linux-amd64
    chmod +x /usr/local/bin/talosctl
  EOF
}

resource "sakura_server" "bastion" {
  name   = "${local.name}-bastion"
  tags   = [var.prefix, local.env, "bastion"]
  core   = var.bastion_cpu
  memory = var.bastion_mem
  disks  = [sakura_disk.bastion.id]

  interface_driver = "virtio"

  network_interface = [
    {
      # eth0: グローバル。ここから SSH で入る
      upstream         = sakura_internet.k8s_external.vswitch_id
      user_ip_address  = local.bastion_ip
      packet_filter_id = sakura_packet_filter.bastion.id
    },
    {
      # eth1: 内部セグメント。ここに DHCP を配る
      upstream        = sakura_vswitch.k8s_internal.id
      user_ip_address = local.bastion_internal_ip
    },
  ]

  # Ubuntu なのでさくらの「ディスクの修正」がそのまま使える
  disk_edit_parameter = {
    hostname   = "${local.name}-bastion"
    ip_address = local.bastion_ip
    gateway    = local.external_gateway
    netmask    = local.external_netmask
    ssh_keys   = var.bastion_ssh_public_keys

    # コンソールから入れるようにパスワードは設定するが、
    # SSH のパスワード認証は無効のまま (鍵のみ)
    password        = random_password.bastion.result
    disable_pw_auth = true

    script = [
      { id = sakura_script.bastion_dhcp.id },
    ]
  }

  timeouts = {
    create = "1h"
    update = "1h"
    delete = "1h"
  }
}
