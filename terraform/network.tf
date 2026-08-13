# ルータ+スイッチ (グローバルIPのセグメント)
# 全ノードがここに繋がる。Talos の shared VIP と Cilium の L2 Announcement も
# このセグメント上で ARP を打つので、同一 L2 に揃えておく必要がある。
resource "sakura_internet" "k8s_external" {
  name       = "${local.name}-external"
  tags       = [var.prefix, local.env]
  netmask    = local.external_netmask
  band_width = var.external_band_width[local.env]

  # とりあえずは IPv4 シングルスタック
  enable_ipv6 = false

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}

# ノード間の内部セグメント (etcd のピア通信・kubelet 等)
resource "sakura_vswitch" "k8s_internal" {
  name = "${local.name}-internal"
  tags = [var.prefix, local.env]

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}
