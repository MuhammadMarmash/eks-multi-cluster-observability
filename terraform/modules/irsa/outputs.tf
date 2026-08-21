###############################################################################
# modules/irsa — outputs
###############################################################################

output "role_arn" {
  description = "ARN of the IRSA role. Annotate the ServiceAccount with eks.amazonaws.com/role-arn set to this."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the IRSA role."
  value       = aws_iam_role.this.name
}

output "assume_role_policy_json" {
  description = "The rendered trust policy. Exposed so the module's own tests, and any policy check in CI, can assert on the sub and aud conditions."
  value       = local.assume_role_policy
}
