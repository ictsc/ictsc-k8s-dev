terraform {
  # sacloud/sakura provider は Terraform 1.11 以降が必要
  required_version = ">= 1.11"

  required_providers {
    sakura = {
      source  = "sacloud/sakura"
      version = "3.12.7"
    }
    # 踏み台のコンソールログイン用パスワードの生成に使う (bastion.tf)
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # bucket は .envrc の TF_CLI_ARGS_init 経由で渡す (direnv が読み込む)
  #   export TF_CLI_ARGS_init="-backend-config=bucket=$TF_STATE_BUCKET"
  # 認証は AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (= オブジェクトストレージのキー) を使う
  backend "s3" {
    endpoints = {
      s3 = "https://s3.isk01.sakurastorage.jp"
    }
    region = "jp-north-1"
    key    = "terraform.tfstate"

    # さくらのオブジェクトストレージ向けの必須設定 (触らない)
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    # さくらのオブジェクトストレージは lock 用の API が未対応
    use_lockfile = false
  }
}

provider "sakura" {
  # token / secret / zone は SAKURACLOUD_* 環境変数から読む (.envrc 参照)
}
