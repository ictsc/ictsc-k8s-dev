terraform {
  required_version = ">= 1.11"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    sakura = {
      source  = "sacloud/sakura"
      version = "3.12.7"
    }
  }

  # Kubernetes クラスタとはライフサイクルを分離する。
  # bucket はルートと同じく TF_CLI_ARGS_init から渡す。
  backend "s3" {
    endpoints = {
      s3 = "https://s3.isk01.sakurastorage.jp"
    }
    region = "jp-north-1"
    key    = "omni/terraform.tfstate"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_lockfile                = false
  }
}

provider "sakura" {}
