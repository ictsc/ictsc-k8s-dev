data "sakura_archive" "ubuntu" {
  os_type = "ubuntu2404"
}

data "sakura_internet" "external" {
  name = var.external_network_name
}

locals {
  name    = "${var.prefix}-omni"
  omni_ip = data.sakura_internet.external.ip_addresses[var.omni_ip_index]
}
