###############################################################################
# modules/lgtm-storage — outputs
#
# The contract stage 2 consumes when it deploys the LGTM Helm releases.
###############################################################################

output "bucket_names" {
  description = "Bucket name per component. Goes into each chart's object-storage config."
  value       = local.bucket_names
}

output "bucket_arns" {
  description = "Bucket ARN per component."
  value       = local.bucket_arns
}

output "irsa_role_arns" {
  description = "IRSA role ARN per component. Annotate each ServiceAccount with eks.amazonaws.com/role-arn set to this."
  value       = { for k, m in module.irsa : k => m.role_arn }
}

output "service_account_names" {
  description = <<-EOT
    ServiceAccount name per component. Stage 2 MUST set the chart's
    serviceAccount.name to these values: the trust policies are pinned to them,
    and the charts' own defaults derive from the Helm release name instead.
  EOT
  value       = { for k, c in var.components : k => c.service_account }
}

output "namespace" {
  description = "Namespace the LGTM stack runs in, and the namespace pinned in every trust policy."
  value       = var.namespace
}

output "policy_documents" {
  description = "The rendered S3 policy per component. Exposed so tests, and any policy check in CI, can assert on scoping without an apply."
  value       = local.policy_documents
}

output "service_account_to_role" {
  description = "Flat namespace/ServiceAccount -> role ARN map. The mapping the Helm values need, in one place."
  value = {
    for k, c in var.components :
    "${var.namespace}/${c.service_account}" => module.irsa[k].role_arn
  }
}
