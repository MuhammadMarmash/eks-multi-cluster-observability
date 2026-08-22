output "state_bucket_name" {
  description = "Name of the state bucket. Feed into `-backend-config=bucket=...`."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "state_kms_key_arn" {
  description = "KMS key encrypting state, or null when using SSE-S3. Feed into `-backend-config=kms_key_id=...`."
  value       = var.use_customer_managed_key ? aws_kms_key.state[0].arn : null
}

output "backend_config_snippet" {
  description = "Copy-paste backend configuration for the consuming root modules."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "prod/platform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
    ${var.use_customer_managed_key ? "kms_key_id   = \"${aws_kms_key.state[0].arn}\"" : ""}
  EOT
}

# --- GitHub Actions ----------------------------------------------------------------

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider, or null when github_repository is unset."
  value       = local.github_oidc_enabled ? aws_iam_openid_connect_provider.github[0].arn : null
}

output "ci_role_arns" {
  description = <<-EOT
    CI role ARNs keyed by purpose. Set these as GitHub Actions repository
    VARIABLES (not secrets — a role ARN is not sensitive, and having it visible
    in logs makes an authentication failure diagnosable):

      AWS_ROLE_PLAN      <- plan
      AWS_ROLE_APPLY     <- apply
      AWS_ROLE_ECR_PUSH  <- ecr_push
  EOT
  value       = { for k, r in aws_iam_role.ci : k => r.arn }
}

output "github_actions_variables" {
  description = "Every repository variable the workflows need, ready to paste into GitHub → Settings → Variables."
  value = local.github_oidc_enabled ? {
    AWS_REGION        = var.aws_region
    AWS_ROLE_PLAN     = aws_iam_role.ci["plan"].arn
    AWS_ROLE_APPLY    = aws_iam_role.ci["apply"].arn
    AWS_ROLE_ECR_PUSH = aws_iam_role.ci["ecr_push"].arn
    TF_STATE_BUCKET   = aws_s3_bucket.state.id
    TF_STATE_KMS_KEY  = var.use_customer_managed_key ? aws_kms_key.state[0].arn : ""
  } : null
}
