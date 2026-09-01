output "omni_ip" {
  value = local.omni_ip
}

output "omni_url" {
  value = "https://${var.omni_domain}"
}

output "dns_records" {
  description = "terraform-ictsc-net側に追加するAレコード"
  value = {
    (var.omni_domain) = local.omni_ip
    (var.auth_domain) = local.omni_ip
  }
}

output "ssh_command" {
  value = "ssh ubuntu@${local.omni_ip}"
}

output "console_password" {
  value     = random_password.omni.result
  sensitive = true
}
