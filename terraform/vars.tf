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

# 必要なグローバルIP数 = control_plane + worker_node + 2 (API VIP / Ingress VIP)
# /28 -> 11個, /27 -> 27個, /26 -> 59個
variable "external_subnet" {
  type = map(number)
  default = {
    dev  = 28
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

########################################
# Talos / Kubernetes
########################################

variable "talos_version" {
  type    = string
  default = "v1.13.8"
}

variable "kubernetes_version" {
  type        = string
  description = "Talos v1.13.8 の既定は 1.36.2"
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
    dev  = 2
    prod = 2
  }
}
variable "worker_node_mem" {
  type = map(number)
  default = {
    dev  = 4
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
