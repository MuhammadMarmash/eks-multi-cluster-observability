###############################################################################
# modules/lgtm-backends — outputs
#
# The in-cluster endpoints the gateway Alloy fans out to. These are exactly the
# values telemetry-gateway's mimir_endpoint / loki_endpoint / tempo_endpoint
# expect, so the root module wires them straight across.
###############################################################################

output "namespace" {
  description = "Namespace the backends run in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "mimir_otlp_endpoint" {
  description = "Mimir OTLP/HTTP write endpoint, through the chart's nginx gateway."
  value       = "http://mimir-gateway.${var.namespace}.svc.cluster.local/otlp"
}

output "loki_otlp_endpoint" {
  description = "Loki OTLP/HTTP write endpoint, through the chart's nginx gateway."
  value       = "http://loki-gateway.${var.namespace}.svc.cluster.local/otlp"
}

output "tempo_otlp_endpoint" {
  description = "Tempo OTLP/gRPC ingest endpoint, host:port. Single-binary chart, so this is the one Tempo Service."
  value       = "tempo.${var.namespace}.svc.cluster.local:4317"
}

# --- Query endpoints, for Grafana's datasources in the next step --------------

output "query_endpoints" {
  description = "In-cluster read endpoints, keyed by component. Grafana's datasources point here."
  value = {
    mimir = "http://mimir-query-frontend.${var.namespace}.svc.cluster.local:8080/prometheus"
    loki  = "http://loki-gateway.${var.namespace}.svc.cluster.local"
    tempo = "http://tempo.${var.namespace}.svc.cluster.local:3200"
  }
}

output "service_account_names" {
  description = "ServiceAccount actually configured per component. Must equal what the IRSA trust policies pin."
  value       = var.service_account_names
}

# --- Rendered values, for assertions ------------------------------------------

output "mimir_values" {
  description = "Mimir Helm values as a structured map."
  value       = local.mimir_values
}

output "loki_values" {
  description = "Loki Helm values as a structured map."
  value       = local.loki_values
}

output "tempo_values" {
  description = "Tempo Helm values as a structured map."
  value       = local.tempo_values
}

output "rendered_values" {
  description = "All three rendered documents, for substring checks such as 'no credential appears anywhere'."
  value = {
    mimir = yamlencode(local.mimir_values)
    loki  = yamlencode(local.loki_values)
    tempo = yamlencode(local.tempo_values)
  }
}
