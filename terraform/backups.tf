# DB data must survive loss of the Kubernetes disks. Each environment has its
# own bucket and bucket-scoped credentials; never reuse Terraform backend keys.
variable "postgres_backup_enabled" {
  description = "Enable only after the target Sakura project can use Object Storage"
  type        = map(bool)
  default     = { dev = true, prod = false }
}

locals {
  postgres_backup_enabled = var.postgres_backup_enabled[local.env]
}

data "sakura_object_storage_site" "backups" {
  count = local.postgres_backup_enabled ? 1 : 0
  id    = var.object_storage_site_id
}

resource "sakura_object_storage_bucket" "postgres_backup" {
  count   = local.postgres_backup_enabled ? 1 : 0
  name    = "${var.object_storage_bucket_prefix}-${local.env}-postgres-backups"
  site_id = data.sakura_object_storage_site.backups[0].id

  lifecycle {
    prevent_destroy = true
  }
}

resource "sakura_object_storage_permission" "postgres_backup" {
  count   = local.postgres_backup_enabled ? 1 : 0
  name    = "${local.name}-postgres-backup"
  site_id = data.sakura_object_storage_site.backups[0].id
  bucket_controls = [{
    bucket    = sakura_object_storage_bucket.postgres_backup[0].name
    can_read  = true
    can_write = true
  }]
}

output "postgres_backup_storage" {
  description = "Environment-specific PostgreSQL backup destination; render values from this output"
  value = local.postgres_backup_enabled ? {
    endpoint = data.sakura_object_storage_site.backups[0].s3_endpoint
    region   = data.sakura_object_storage_site.backups[0].region
    bucket   = sakura_object_storage_bucket.postgres_backup[0].name
  } : null
}

output "postgres_backup_credentials" {
  description = "Bucket-scoped credentials for scoreserver/postgres-backup-s3; keep out of Git/logs"
  sensitive   = true
  value = local.postgres_backup_enabled ? {
    ACCESS_KEY_ID     = sakura_object_storage_permission.postgres_backup[0].access_key
    ACCESS_SECRET_KEY = sakura_object_storage_permission.postgres_backup[0].secret_key
  } : null
}
