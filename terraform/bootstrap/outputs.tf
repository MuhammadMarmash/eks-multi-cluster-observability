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
