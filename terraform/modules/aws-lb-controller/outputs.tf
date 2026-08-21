###############################################################################
# modules/aws-lb-controller — outputs
###############################################################################

output "irsa_role_arn" {
  description = "ARN of the controller's IRSA role."
  value       = module.irsa.role_arn
}

output "service_account_name" {
  description = "ServiceAccount the controller runs as. Pinned in the IRSA trust policy."
  value       = local.service_account_name
}

output "release_name" {
  description = "Helm release name. Depend on this from any module that creates a Service of type LoadBalancer."
  value       = helm_release.this.name
}

output "inline_policy_json" {
  description = "The compacted IAM policy actually sent to AWS. Exposed so a test can assert it still fits inside IAM's inline-policy limit."
  value       = local.inline_policy_json
}

output "values" {
  description = <<-EOT
    The Helm values as a structured map. Assert against this rather than the
    rendered string: yamlencode quotes every key, so substring matching on the
    rendered form couples the test to a formatting detail rather than to the
    decision being tested.
  EOT
  value       = local.values
}

output "rendered_values" {
  description = "The values document handed to Helm. Useful for checking that a substring — an upstream registry, say — appears nowhere in the document."
  value       = yamlencode(local.values)
}
