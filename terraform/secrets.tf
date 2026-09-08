# Secret の値は ESO/移行スクリプトで扱い、Terraform state に保存しない。
resource "sakura_kms" "secrets" {
  count       = local.env == "dev" ? 1 : 0
  name        = "${local.name}-secrets"
  description = "Encryption key for Kubernetes application secrets"
  key_origin  = "generated"
  tags        = [local.name]

  lifecycle {
    prevent_destroy = true
  }
}

resource "sakura_secret_manager" "kubernetes" {
  count       = local.env == "dev" ? 1 : 0
  name        = "${local.name}-secrets"
  description = "Kubernetes application secrets synchronized by ESO"
  kms_key_id  = sakura_kms.secrets[0].id
  tags        = [local.name]

  lifecycle {
    prevent_destroy = true
  }
}

output "secret_manager_vault_id" {
  description = "ESO 用シークレット保管庫 ID (dev のみ)"
  value       = local.env == "dev" ? sakura_secret_manager.kubernetes[0].id : null
}
