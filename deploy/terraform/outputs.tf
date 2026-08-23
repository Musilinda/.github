output "static_ip" {
  description = "Public static IP — point DNS (app./learn./www.$domain) here."
  value       = aws_lightsail_static_ip.ip.ip_address
}

output "instance_name" {
  description = "Lightsail instance name."
  value       = aws_lightsail_instance.box.name
}

output "domain" {
  description = "Base domain this env serves."
  value       = var.domain
}
