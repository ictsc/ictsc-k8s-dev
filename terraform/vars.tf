variable "prefix" {
  type        = string
  description = "全リソース名の接頭辞"
  default     = "ictsc"
}

variable "domain" {
  type = map(string)
  default = {
    dev  = "k8s-dev.ictsc.net"
    prod = "k8s.ictsc.net"
  }
}

# ネットワーク

# 必要なグローバル IP 数は control_plane + worker_node + 3。
# WARNING: netmask を変えると sakura_internet が作り直しになる。さくらのクラウドは
# サーバ接続中は削除できないため、変更時は task destroy 後に再構築する。
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

# Talos / Kubernetes

# WARNING: ここを上げても稼働中のノードの OS は上がらない。
#          task upgrade-talos 後、新規ノード用にこの値と aqua.yaml も揃える。
variable "talos_version" {
  type = string
  # renovate: datasource=github-releases depName=siderolabs/talos
  default = "v1.13.8"
}

# この値も新規クラスタ用。稼働中の更新には task upgrade-k8s を使う。
variable "kubernetes_version" {
  type        = string
  description = "新しく作るクラスタの Kubernetes バージョン"
  # renovate: datasource=github-releases depName=kubernetes/kubernetes
  default = "1.36.4"
}

variable "pod_subnet" {
  type    = string
  default = "10.244.0.0/16"
}

variable "service_subnet" {
  type    = string
  default = "10.96.0.0/12"
}

# Control Plane

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

# NFS (PersistentVolume 用)
variable "nfs_plan" {
  type        = map(string)
  description = "NFS アプライアンスのプラン (hdd / ssd)"
  default = {
    dev  = "ssd"
    prod = "ssd"
  }
}

variable "nfs_size" {
  type        = map(number)
  description = "NFS アプライアンスの容量 (GiB)"
  default = {
    dev  = 20
    prod = 100
  }
}

# 踏み台

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

# Worker Node

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
