# These feed the MAIN deploy/terraform S3 backend + the GitHub Actions workflow.
output "state_bucket" {
  description = "S3 bucket name — put this in the main terraform's backend + workflow."
  value       = aws_s3_bucket.tfstate.id
}

output "gha_role_arn" {
  description = "Role ARN Actions assumes via OIDC — set as workflow `role-to-assume`."
  value       = aws_iam_role.gha.arn
}
