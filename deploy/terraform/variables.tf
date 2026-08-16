variable "env" {
  description = "Environment name (dev | prod). Drives resource names + tags."
  type        = string
}

variable "domain" {
  description = "Base domain for this env (e.g. dev.musilinda.com | musilinda.com)."
  type        = string
}

variable "bundle_id" {
  description = "Lightsail bundle (box size): medium_2_0 = 4GB, large_2_0 = 8GB."
  type        = string
  default     = "large_2_0"
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AZ within the region (e.g. us-east-1a)."
  type        = string
  default     = "us-east-1a"
}

variable "dry_run" {
  description = "true = configure the provider for offline `plan` (skip live cred/metadata calls). Leave false for real apply."
  type        = bool
  default     = false
}
