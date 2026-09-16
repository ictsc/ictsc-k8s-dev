terraform {
  required_version = ">= 1.11"
  required_providers {
    omni = {
      source  = "siderolabs/omni"
      version = "0.1.0-alpha.3"
    }
  }
  backend "s3" {
    endpoints = {
      s3 = "https://s3.isk01.sakurastorage.jp"
    }
    region = "jp-north-1"
    key    = "omni/clusters/prod/terraform.tfstate"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_lockfile                = false
  }
}
provider "omni" {
  endpoint = "https://omni.ictsc.net"
}
