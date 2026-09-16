variable "nodes" {
  description = "Omniに参加したprodノード。キーはhostname、machine_idはOmniのUUID。"
  type = map(object({
    machine_id  = string
    role        = string
    external_ip = string
    internal_ip = string
  }))
  validation {
    condition = (
      length(var.nodes) == 6 &&
      length([for node in var.nodes : node if node.role == "controlplane"]) == 3 &&
      length([for node in var.nodes : node if node.role == "worker"]) == 3 &&
      length(distinct([for node in var.nodes : node.machine_id])) == 6 &&
      alltrue([for name in keys(var.nodes) : startswith(name, "ictsc-prod-")])
    )
    error_message = "prod専用のcontrol plane 3台、worker 3台を重複なしで指定してください。"
  }
}

variable "external_gateway" {
  type = string
}

variable "external_prefix" {
  type    = number
  default = 27
}

resource "omni_cluster" "prod" {
  name               = "ictsc-prod"
  talos_version      = "1.13.9"
  kubernetes_version = "1.36.4"
  backup_interval    = "1h"
  lifecycle {
    prevent_destroy = true
  }
}

resource "omni_machine_set" "controlplane" {
  cluster = omni_cluster.prod.name
  role    = "controlplane"
}

resource "omni_machine_set" "workers" {
  cluster = omni_cluster.prod.name
  role    = "workers"
}

resource "omni_machine_extensions" "storage" {
  cluster    = omni_cluster.prod.name
  extensions = ["siderolabs/iscsi-tools", "siderolabs/util-linux-tools"]
}

resource "omni_config_patch" "common" {
  name    = "prod-common"
  cluster = omni_cluster.prod.name
  data = yamlencode({
    machine = {
      install = { disk = "/dev/vda", wipe = false }
      features = {
        kubePrism = { enabled = true, port = 7445 }
        hostDNS   = { enabled = true, forwardKubeDNSToHost = true }
      }
      time = { servers = ["ntp1.sakura.ad.jp", "ntp2.sakura.ad.jp"] }
      kubelet = {
        nodeIP    = { validSubnets = ["192.168.100.0/24"] }
        extraArgs = { rotate-server-certificates = "true" }
      }
    }
    cluster = {
      network = {
        cni            = { name = "none" }
        podSubnets     = ["10.244.0.0/16"]
        serviceSubnets = ["10.96.0.0/12"]
      }
      proxy = { disabled = true }
    }
  })
}

resource "omni_config_patch" "controlplane" {
  name     = "prod-etcd-internal"
  cluster  = omni_cluster.prod.name
  selector = { machine_set = omni_machine_set.controlplane.name }
  data = yamlencode({
    cluster = {
      etcd = {
        advertisedSubnets = ["192.168.100.0/24"]
        extraArgs         = { listen-metrics-urls = "http://0.0.0.0:2381" }
      }
      controllerManager = { extraArgs = { bind-address = "0.0.0.0" } }
      scheduler         = { extraArgs = { bind-address = "0.0.0.0" } }
    }
  })
}

resource "omni_config_patch" "workers" {
  name     = "prod-longhorn"
  cluster  = omni_cluster.prod.name
  selector = { machine_set = omni_machine_set.workers.name }
  data     = file("${path.module}/../../../talos/patches/worker.yaml")
}

resource "omni_config_patch" "network" {
  for_each = var.nodes
  name     = "prod-network-${each.key}"
  cluster  = omni_cluster.prod.name
  selector = { cluster_machine = each.value.machine_id }
  data     = file("${path.module}/../../../talos/build/ictsc-prod/patches/${each.key}.yaml")
}

resource "omni_machine_set_node" "nodes" {
  for_each    = var.nodes
  cluster     = omni_cluster.prod.name
  machine_id  = each.value.machine_id
  machine_set = each.value.role == "controlplane" ? omni_machine_set.controlplane.name : omni_machine_set.workers.name
  depends_on = [
    omni_config_patch.common, omni_config_patch.controlplane,
    omni_config_patch.workers, omni_config_patch.network,
    omni_machine_extensions.storage,
  ]
}
