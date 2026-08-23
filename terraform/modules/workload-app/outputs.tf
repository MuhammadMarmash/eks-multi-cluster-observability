###############################################################################
# modules/workload-app — outputs
###############################################################################

output "namespace" {
  description = "Namespace the application runs in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "frontend_port_forward" {
  description = "Reach the storefront. It is ClusterIP; the load generator drives traffic without it."
  value       = "kubectl -n ${var.namespace} port-forward svc/otel-demo-frontend-proxy 8080:8080"
}

output "values" {
  description = "Helm values as a structured map, for assertions."
  value       = local.values
}

output "rendered_values" {
  description = "The values document handed to Helm."
  value       = yamlencode(local.values)
}
