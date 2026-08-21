###############################################################################
# modules/telemetry-agent — outputs
###############################################################################

output "namespace" {
  description = "Namespace the agent runs in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "otlp_endpoint" {
  description = "In-cluster OTLP/gRPC endpoint the instrumented workloads should send to. Point the Boutique's OTEL_EXPORTER_OTLP_ENDPOINT at this."
  value       = "http://${local.release_name}.${kubernetes_namespace_v1.this.metadata[0].name}.svc.cluster.local:4317"
}

output "values" {
  description = "The Helm values as a structured map. Assert against this rather than the rendered string; yamlencode quotes every key."
  value       = local.values
}

output "rendered_config" {
  description = "The rendered .alloy config. Exposed so tests can assert on routing, verification and node scoping without an apply."
  value       = local.config
}

output "rendered_values" {
  description = "The values document handed to Helm."
  value       = yamlencode(local.values)
}
