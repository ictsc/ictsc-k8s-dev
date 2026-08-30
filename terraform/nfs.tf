# NFS アプライアンス (Kubernetes の PersistentVolume 用)
#
# 内部セグメント (vSwitch) に置くのでグローバル IP を消費せず、
# パケットフィルタの対象にもならない。ノードからは eth1 経由で見える。
#
# Kubernetes 側は上流の csi-driver-nfs を使う。さくら専用の CSI ドライバは不要。
#
# NOTE: worker に生ディスクを足して rook-ceph を組む案もあるが、現状ノードは
#       OS 用の 40GB が1本だけで Ceph に渡せるディスクが無い。ディスクを
#       足すと 20GB×3本 (レプリカ3で実効 20GB) になり、NFS SSD 20GB との
#       差は月 660円ほど。OSD がノードのメモリと CPU を食うこと、ノード再起動の
#       たびにリバランスが走ることを考えると、dev では見合わないと判断した。
resource "sakura_nfs" "main" {
  name = "${local.name}-nfs"
  tags = [var.prefix, local.env]
  plan = var.nfs_plan[local.env]
  size = var.nfs_size[local.env]

  network_interface = {
    vswitch_id = sakura_vswitch.k8s_internal.id
    ip_address = local.nfs_internal_ip
    netmask    = tonumber(local.internal_netmask)
    # 内部セグメントに閉じるのでデフォルトゲートウェイは持たせない
  }

  timeouts = {
    create = "1h"
    delete = "1h"
  }
}
