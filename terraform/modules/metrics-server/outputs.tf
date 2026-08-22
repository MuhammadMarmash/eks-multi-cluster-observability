###############################################################################
# modules/metrics-server — outputs
###############################################################################

output "release_name" {
  description = "Helm release name. Depend on this from anything that defines a HorizontalPodAutoscaler."
  value       = helm_release.this.name
}

output "namespace" {
  description = "Namespace metrics-server runs in."
  value       = var.namespace
}

output "values" {
  description = "Helm values as a structured map, for assertions."
  value       = local.values
}

output "rendered_values" {
  description = "The values document handed to Helm."
  value       = yamlencode(local.values)
}
