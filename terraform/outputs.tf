# talos/scripts/gen-config.sh がそのまま食える形で出す
output "talos_input" {
  description = "Talos machine config 生成スクリプトへの入力"
  value       = local.talos_input
}

output "cluster_endpoint" {
  value = local.cluster_endpoint
}

output "api_vip" {
  value = local.api_vip
}

output "ingress_vip" {
  value = local.ingress_vip
}

output "control_plane_ips" {
  value = local.control_plane_ips
}

output "worker_node_ips" {
  value = local.worker_node_ips
}

output "external_cidr" {
  value = local.external_cidr
}

output "domain" {
  value = local.domain
}

# さくらのクラウドに DNS ゾーンは作らないので、クライアント側の /etc/hosts に貼る。
#   $ terraform output -raw hosts_entries | sudo tee -a /etc/hosts
output "hosts_entries" {
  description = "/etc/hosts に追記する行"
  value = join("\n", concat(
    [
      "# --- ${local.name} (terraform output hosts_entries) ---",
      "${local.api_vip} k8s.${local.domain}",
      "${local.ingress_vip} ${local.domain} argocd.${local.domain}",
    ],
    [for n in local.talos_input.nodes : "${n.external_ip} ${n.hostname}"],
  ))
}

output "bastion_ip" {
  description = "踏み台のグローバルIP (ssh ubuntu@<ip>)"
  value       = local.bastion_ip
}

output "bastion_password" {
  description = "踏み台のコンソールログイン用パスワード (ユーザは ubuntu)"
  value       = random_password.bastion.result
  sensitive   = true
}

output "nfs_ip" {
  description = "NFS アプライアンスの内部 IP (csi-driver-nfs の StorageClass が使う)"
  value       = sakura_nfs.main.network_interface.ip_address
}

output "observability_object_storage" {
  description = "Loki / Tempo 用 Object Storage の接続先とバケット名 (dev のみ)"
  value = local.env == "dev" ? {
    endpoint = data.sakura_object_storage_site.observability[0].s3_endpoint
    region   = data.sakura_object_storage_site.observability[0].region
    buckets  = local.observability_bucket_names
  } : null
}

output "loki_object_storage_credentials" {
  description = "Loki 用 Object Storage 認証情報 (dev のみ)"
  sensitive   = true
  value = local.env == "dev" ? {
    access_key = sakura_object_storage_permission.loki[0].access_key
    secret_key = sakura_object_storage_permission.loki[0].secret_key
  } : null
}

output "tempo_object_storage_credentials" {
  description = "Tempo 用 Object Storage 認証情報 (dev のみ)"
  sensitive   = true
  value = local.env == "dev" ? {
    access_key = sakura_object_storage_permission.tempo[0].access_key
    secret_key = sakura_object_storage_permission.tempo[0].secret_key
  } : null
}
