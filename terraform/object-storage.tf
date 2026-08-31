# Loki と Tempo の永続データを置く Object Storage。
# 現時点では dev だけを対象とし、prod workspace では何も作成しない。
locals {
  observability_bucket_names = local.env == "dev" ? {
    loki_chunks = "${var.object_storage_bucket_prefix}-${local.env}-loki-chunks"
    loki_ruler  = "${var.object_storage_bucket_prefix}-${local.env}-loki-ruler"
    loki_admin  = "${var.object_storage_bucket_prefix}-${local.env}-loki-admin"
    tempo       = "${var.object_storage_bucket_prefix}-${local.env}-tempo-traces"
  } : {}
}

data "sakura_object_storage_site" "observability" {
  count = local.env == "dev" ? 1 : 0
  id    = var.object_storage_site_id
}

resource "sakura_object_storage_bucket" "observability" {
  for_each = local.observability_bucket_names

  name    = each.value
  site_id = data.sakura_object_storage_site.observability[0].id
}

# Loki からは Loki 用の3バケットだけを読み書きできるようにする。
resource "sakura_object_storage_permission" "loki" {
  count = local.env == "dev" ? 1 : 0

  name    = "${var.object_storage_bucket_prefix}-${local.env}-loki"
  site_id = data.sakura_object_storage_site.observability[0].id
  bucket_controls = [
    for key in ["loki_chunks", "loki_ruler", "loki_admin"] : {
      bucket    = sakura_object_storage_bucket.observability[key].name
      can_read  = true
      can_write = true
    }
  ]
}

# Tempo の認証情報を Loki と分離し、trace バケットだけに限定する。
resource "sakura_object_storage_permission" "tempo" {
  count = local.env == "dev" ? 1 : 0

  name    = "${var.object_storage_bucket_prefix}-${local.env}-tempo"
  site_id = data.sakura_object_storage_site.observability[0].id
  bucket_controls = [{
    bucket    = sakura_object_storage_bucket.observability["tempo"].name
    can_read  = true
    can_write = true
  }]
}
