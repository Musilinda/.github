variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_name" {
  description = "S3 bucket for terraform state. MUST be globally unique — change if taken."
  type        = string
  default     = "musilinda-tfstate"
}

variable "github_org" {
  type    = string
  default = "Musilinda"
}

variable "allowed_subjects" {
  description = "Which GitHub repo:branch identities may assume the deploy role. Default: any org repo on dev/main only (PR branches can't deploy)."
  type        = list(string)
  default = [
    "repo:Musilinda/*:ref:refs/heads/dev",
    "repo:Musilinda/*:ref:refs/heads/main",
    # jobs that use `environment:` get an :environment: subject, not :ref:
    "repo:Musilinda/*:environment:dev",
    "repo:Musilinda/*:environment:prod",
  ]
}

variable "plan_subjects" {
  description = "OIDC subjects allowed to assume the READ-ONLY PR-plan role. Only this repo's pull_request subject — PRs can plan, never apply."
  type        = list(string)
  default     = ["repo:Musilinda/.github:pull_request"]
}
