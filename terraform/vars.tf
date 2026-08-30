########################################
# 全体
########################################

variable "prefix" {
  type        = string
  description = "全リソース名の接頭辞"
  default     = "ictsc"
}

# さくらのクラウドには DNS ゾーンを作らない。
# クラスタ内の証明書 (certSANs) と Argo CD のホスト名に使うだけなので、
# 名前解決はクライアント側の /etc/hosts で行う (`terraform output hosts_entries`)
variable "domain" {
  type = map(string)
  default = {
    dev  = "k8s-dev.ictsc.net"
    prod = "k8s.ictsc.net"
  }
}

########################################
# ネットワーク
########################################

# 必要なグローバルIP数 = control_plane + worker_node + 3
#   +3 の内訳: API VIP / Ingress VIP / 踏み台 (割り当ては locals.tf を参照)
# /28 -> 11個, /27 -> 27個, /26 -> 59個
#
# WARNING: netmask を変えると sakura_internet が作り直しになる。さくらのクラウドは
#          サーバが接続されたままのルータ+スイッチを削除させてくれないので、
#          `terraform apply` はサーバを消さずにルータだけ消そうとして延々ハングする
#          (`-target=sakura_internet.k8s_external` でも同じ)。
#          変更するときは `task destroy` で全部消してから作り直すこと。
#          そのため最初から余裕を持たせておく。
#
#          どうしても後から足したい場合の逃げ道として sakura_subnet
#          (コントロールパネルの「スタティックルート追加」) がある。ルータを
#          作り直さずに /26-/28 のブロックを追加できるが、追加ブロックは同一 L2
#          ではなく next_hop に指定したサーバ経由のルーティングになる。
#          Talos の shared VIP と Cilium の L2 Announcement は同一 L2 を要求するので
#          VIP には使えない。使えるのは転送さえ通れば良い worker の eth0 まで。
variable "external_subnet" {
  type = map(number)
  default = {
    dev  = 27
    prod = 27
  }
}

variable "external_band_width" {
  type = map(number)
  default = {
    dev  = 100
    prod = 500
  }
}

variable "nameservers" {
  type        = list(string)
  description = "ノードが引く再帰DNS。さくらのクラウド 東京第1/第2: 210.188.224.10 / 210.188.224.11、石狩第1/第2: 133.242.0.3 / 133.242.0.4"
  default     = ["210.188.224.10", "210.188.224.11"]
}

variable "internal_network" {
  type        = string
  description = "ノード間内部通信 (etcd / kubelet 以外) 用のセグメント"
  default     = "192.168.100.0/24"
}

variable "admin_source_networks" {
  type        = list(string)
  description = <<-EOT
    踏み台を経由せずに kubectl (6443) / talosctl (50000) を叩ける送信元 CIDR。
    踏み台の IP は常に許可されるのでここに書く必要はない。
    空のままだと手元から直接 kubectl / talosctl が打てなくなる
    (踏み台経由の SSH トンネルが必要になる)。
    単一ホストは "/32" を付けないこと。さくらのパケットフィルタは
    マスク長 0〜31 しか受け付けず、/32 を渡すと API が 400 を返す
    (付いていても terraform 側で落とすが、付けない方が意図が明確)。
    例: ["203.0.113.10"]
  EOT
  default     = []
}

########################################
# Talos / Kubernetes
########################################

# WARNING: ここを上げても稼働中のノードの OS は上がらない。
#          これは「これから作るノードのディスクの元になるアーカイブ」の指定であって、
#          既存ノードには影響しない (sakura_disk 側で ignore_changes して守ってある。
#          守っていないと全ディスクが作り直しになり、etcd も machine config も消える)。
#
#          OS を上げるときは talosctl を使うこと:
#            task upgrade-talos TO=v1.13.9
#          その後この値と aqua.yaml の siderolabs/talos も揃えておく。
variable "talos_version" {
  type    = string
  default = "v1.13.8"
}

# talos_version と同じく、ここを変えても稼働中のクラスタは上がらない。
# Kubernetes を上げるときは talosctl に任せること:
#   task upgrade-k8s TO=1.36.4
# なお talosctl v1.13.8 の既定値は 1.36.2 なので、--to を省くと
# 現在の 1.36.3 からダウングレードになる。task 側で TO を必須にしてある。
variable "kubernetes_version" {
  type        = string
  description = "新しく作るクラスタの Kubernetes バージョン"
  default     = "1.36.3"
}

variable "pod_subnet" {
  type    = string
  default = "10.244.0.0/16"
}

variable "service_subnet" {
  type    = string
  default = "10.96.0.0/12"
}

########################################
# Control Plane
########################################

# NOTE: 使えるサーバスペックの上限が 2コア / 4GB なので、dev / prod とも
#       *_cpu = 2 / *_mem = 4 が上限。これを超えると apply が通らない。

variable "control_plane" {
  type = map(number)
  default = {
    dev  = 3
    prod = 3
  }
}
variable "control_plane_cpu" {
  type = map(number)
  default = {
    dev  = 2
    prod = 2
  }
}
variable "control_plane_mem" {
  type = map(number)
  default = {
    dev  = 4
    prod = 4
  }
}
variable "control_plane_disk" {
  type = map(number)
  default = {
    dev  = 40
    prod = 40
  }
}

########################################
# 踏み台
########################################

# Talos ノードは machine config が入るまでネットワークを持たない。
# ルータ+スイッチには DHCP が無いので、内部セグメントに DHCP を配る踏み台を置く。
# 詳細は bastion.tf を参照。

variable "bastion_cpu" {
  type    = number
  default = 2
}
variable "bastion_mem" {
  type    = number
  default = 4
}
variable "bastion_disk" {
  type    = number
  default = 20
}
variable "bastion_ssh_public_keys" {
  type        = list(string)
  description = "踏み台に登録する SSH 公開鍵。メンバーぶん並べてよい (公開鍵なので commit して差し支えない)"
}

########################################
# Worker Node
########################################

variable "worker_node" {
  type = map(number)
  default = {
    dev  = 3
    prod = 6
  }
}
variable "worker_node_cpu" {
  type = map(number)
  default = {
    dev  = 6
    prod = 2
  }
}
variable "worker_node_mem" {
  type = map(number)
  default = {
    dev  = 12
    prod = 4
  }
}
variable "worker_node_disk" {
  type = map(number)
  default = {
    dev  = 40
    prod = 80
  }
}
