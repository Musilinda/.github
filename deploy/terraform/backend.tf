terraform {
  # State lives in the S3 bucket the bootstrap created, so CI (ephemeral runners)
  # shares it. `key` is supplied per-env at init so dev/prod state stay separate:
  #   terraform init -backend-config="key=dev/terraform.tfstate"
  #   terraform init -backend-config="key=prod/terraform.tfstate"
  backend "s3" {
    bucket       = "musilinda-tfstate"
    region       = "us-east-1"
    use_lockfile = true # S3 native state locking (no DynamoDB needed)
  }
}
