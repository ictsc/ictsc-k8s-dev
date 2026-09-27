# Owned by ICTSC common resources, independent of either Kubernetes workspace.
locals {
  buckets = {
    prod_postgres = "ictsc-void-k8s-prod-postgres-backups"
    omni          = "ictsc-omni-backups"
  }
}
data "sakura_object_storage_site" "backups" { id = "isk01" }
resource "sakura_object_storage_bucket" "backup" {
  for_each = local.buckets
  name     = each.value
  site_id  = data.sakura_object_storage_site.backups.id
  lifecycle { prevent_destroy = true }
}
resource "sakura_object_storage_permission" "backup" {
  for_each = local.buckets
  name     = each.value
  site_id  = data.sakura_object_storage_site.backups.id
  bucket_controls = [{
    bucket    = sakura_object_storage_bucket.backup[each.key].name
    can_read  = true
    can_write = true
  }]
  lifecycle { prevent_destroy = true }
}
resource "sakura_kms" "recovery" {
  name        = "ictsc-recovery-secrets"
  description = "Encryption key for off-cluster recovery credentials"
  key_origin  = "generated"
  lifecycle { prevent_destroy = true }
}
resource "sakura_secret_manager" "recovery" {
  name        = "ictsc-recovery-secrets"
  description = "DB and Omni backup credentials and GitOps recovery bundles"
  kms_key_id  = sakura_kms.recovery.id
  lifecycle { prevent_destroy = true }
}
output "storage" {
  value = {
    endpoint = data.sakura_object_storage_site.backups.s3_endpoint
    region   = data.sakura_object_storage_site.backups.region
    buckets  = local.buckets
    vault_id = sakura_secret_manager.recovery.id
  }
}
output "credentials" {
  sensitive = true
  value = { for key, permission in sakura_object_storage_permission.backup : key => {
    ACCESS_KEY_ID     = permission.access_key
    ACCESS_SECRET_KEY = permission.secret_key
  } }
}
