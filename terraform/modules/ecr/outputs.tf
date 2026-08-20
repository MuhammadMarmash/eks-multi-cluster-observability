###############################################################################
# modules/ecr — outputs
###############################################################################

output "repository_urls" {
  description = "Repository URIs keyed by repository name. These are the values that go into image references and `helm push oci://...`."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  description = "Repository ARNs keyed by repository name. Use these to scope IAM policies to specific repositories instead of ecr:*."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}

output "repository_names" {
  description = "Repository names."
  value       = keys(aws_ecr_repository.this)
}

output "registry_id" {
  description = "AWS account ID that owns the registry."
  value       = data.aws_caller_identity.current.account_id
}

output "registry_url" {
  description = "Base registry URL — the target of `docker login` and `helm registry login`."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
}

output "docker_login_command" {
  description = "Ready-to-run command to authenticate Docker and Helm against this registry."
  value       = "aws ecr get-login-password --region ${data.aws_region.current.region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
}

output "image_tag_mutability" {
  description = "Tag mutability enforced across all repositories in this module."
  value       = var.image_tag_mutability
}
