###############################################################################
# modules/cert-manager — outputs
###############################################################################

output "namespace" {
  description = "Namespace cert-manager runs in, and the namespace a ClusterIssuer of type `ca` reads its signing secret from."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "release_name" {
  description = "Helm release name. Depend on this from any module that creates a Certificate."
  value       = helm_release.this.name
}

output "values" {
  description = "The Helm values as a structured map. Assert against this rather than the rendered string; yamlencode quotes every key."
  value       = local.values
}

output "rendered_values" {
  description = "The values document handed to Helm. Useful for checking that a substring — an upstream registry, say — appears nowhere in the document."
  value       = yamlencode(local.values)
}
