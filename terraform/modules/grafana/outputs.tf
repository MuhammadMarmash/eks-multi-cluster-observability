###############################################################################
# modules/grafana — outputs
###############################################################################

output "namespace" {
  description = "Namespace Grafana runs in."
  value       = var.namespace
}

output "admin_user" {
  description = "Grafana admin username."
  value       = var.admin_user
}

output "admin_password" {
  description = "Grafana admin password. Generated, never committed."
  value       = random_password.admin.result
  sensitive   = true
}

output "port_forward_command" {
  description = "Reach the console. Grafana is ClusterIP on purpose — a second load balancer for a demo would double this layer's hourly cost."
  value       = "kubectl -n ${var.namespace} port-forward svc/grafana 3000:80"
}

output "datasource_uids" {
  description = "Stable datasource UIDs. Provisioned dashboards reference these, so they must not drift."
  value       = [for d in local.datasources : d.uid]
}

output "values" {
  description = "Helm values as a structured map. Assert against this rather than the rendered string; yamlencode quotes every key."
  value       = local.values
}

output "rendered_values" {
  description = "The values document handed to Helm."
  value       = yamlencode(local.values)
}
