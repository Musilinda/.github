provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Terraform state bucket — the MAIN deploy/terraform uses this as its S3 backend
# so CI runs (ephemeral runners) share state. Versioned + encrypted + private.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name
  tags   = { Project = "musilinda", Purpose = "terraform-state" }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# GitHub OIDC — lets Actions get short-lived AWS creds (no long-lived keys).
# ---------------------------------------------------------------------------
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# ---------------------------------------------------------------------------
# Role Actions assumes — trust scoped to dev/main of your org repos only.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.allowed_subjects
    }
  }
}

resource "aws_iam_role" "gha" {
  name               = "musilinda-gha-deploy"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = { Project = "musilinda" }
}

# Least-privilege: only Lightsail + the state bucket. No broad account access.
data "aws_iam_policy_document" "perms" {
  statement {
    sid       = "Lightsail"
    actions   = ["lightsail:*"]
    resources = ["*"]
  }
  statement {
    sid       = "TerraformState"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
  }
}

resource "aws_iam_role_policy" "gha" {
  name   = "musilinda-gha-perms"
  role   = aws_iam_role.gha.id
  policy = data.aws_iam_policy_document.perms.json
}
