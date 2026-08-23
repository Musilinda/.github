provider "aws" {
  region = var.aws_region

  # dry_run=true lets `terraform plan` run offline (no live AWS creds/metadata).
  # Keep false for a real apply so credentials are actually validated.
  skip_credentials_validation = var.dry_run
  skip_requesting_account_id  = var.dry_run
  skip_metadata_api_check     = var.dry_run
}

locals {
  name = "musilinda-${var.env}"
  tags = {
    Project = "musilinda"
    Env     = var.env
    Managed = "terraform"
  }
}

# SSH key the CI deploy job uses to reach the box (public key from a GH variable).
resource "aws_lightsail_key_pair" "deploy" {
  count      = var.ssh_public_key == "" ? 0 : 1
  name       = "${local.name}-key"
  public_key = var.ssh_public_key
}

# The one box: Ubuntu 24.04, size per env. The CI deploy job SSHes in to run
# bootstrap.sh (Lightsail has no IAM roles, so the box can't self-pull).
resource "aws_lightsail_instance" "box" {
  name              = local.name
  availability_zone = var.availability_zone
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = var.bundle_id
  key_pair_name     = var.ssh_public_key == "" ? null : aws_lightsail_key_pair.deploy[0].name

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    domain = var.domain
    env    = var.env
  })

  tags = local.tags
}

# Stable public IP (so DNS for app./learn./www.$domain doesn't change on restarts).
resource "aws_lightsail_static_ip" "ip" {
  name = "${local.name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "ip_attach" {
  static_ip_name = aws_lightsail_static_ip.ip.name
  instance_name  = aws_lightsail_instance.box.name
}

# Firewall: ONLY 80/443 public (+22 for admin). Flask 5000 and the node apps
# 5001/5002 are never opened — they stay localhost-only (the security boundary).
resource "aws_lightsail_instance_public_ports" "ports" {
  instance_name = aws_lightsail_instance.box.name

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
  }
  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
  }
  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
  }
}
