variable "prefix" {
  type    = string
  default = "ictsc"
}

variable "external_network_name" {
  type        = string
  description = "Omni VMを接続する既存のルータ+スイッチ"
  default     = "ictsc-dev-external"
}

variable "omni_ip_index" {
  type        = number
  description = "既存ルータ+スイッチのip_addresses内でOmniに割り当てる位置"
  default     = 9
}

variable "omni_domain" {
  type    = string
  default = "omni.ictsc.net"
}

variable "auth_domain" {
  type    = string
  default = "auth.omni.ictsc.net"
}

variable "omni_cpu" {
  type    = number
  default = 2
}

variable "omni_mem" {
  type    = number
  default = 8
}

variable "omni_disk" {
  type    = number
  default = 250
}

# 既存 terraform/terraform.tfvars を -var-file で共用するため名前を揃える。
variable "bastion_ssh_public_keys" {
  type        = list(string)
  description = "Omni VMへ登録するSSH公開鍵"
}
