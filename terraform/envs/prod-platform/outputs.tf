###############################################################################
# envs/prod-platform — outputs
###############################################################################

output "gateway_dns_name" {
  description = "Name Cluster A connects to, and the SAN on the gateway certificate."
  value       = module.gateway.gateway_dns_name
}

output "gateway_endpoint" {
  description = "host:port the agent exports to."
  value       = module.gateway.gateway_endpoint
}

output "nlb_hostname" {
  description = "AWS-generated name of the internal NLB. Compare against what the CNAME resolves to when diagnosing a resolution failure."
  value       = module.gateway.nlb_hostname
}

output "private_zone_id" {
  description = "Hosted zone ID. Section 3's LGTM services get their names here too."
  value       = module.dns.zone_id
}

output "gateway_ca_certificate" {
  description = "CA that signed the gateway certificate. Compare against the copy on Cluster A when a handshake fails on the SAN."
  value       = module.gateway.ca_certificate_pem
}

output "agent_otlp_endpoint" {
  description = "In-cluster OTLP endpoint on Cluster A. Point the Boutique's OTEL_EXPORTER_OTLP_ENDPOINT here."
  value       = module.agent.otlp_endpoint
}

output "telemetry_namespace" {
  description = "Namespace the agent and gateway run in, on their respective clusters."
  value       = var.telemetry_namespace
}

# --- LGTM backends -------------------------------------------------------------

# These are exactly what module.gateway's mimir_endpoint / loki_endpoint /
# tempo_endpoint expect. Wiring them across and flipping lgtm_enabled is the
# next step, deliberately left for its own change.
output "lgtm_write_endpoints" {
  description = "In-cluster OTLP write endpoints the gateway Alloy will fan out to."
  value = {
    mimir = module.lgtm_backends.mimir_otlp_endpoint
    loki  = module.lgtm_backends.loki_otlp_endpoint
    tempo = module.lgtm_backends.tempo_otlp_endpoint
  }
}

output "lgtm_query_endpoints" {
  description = "In-cluster read endpoints. Grafana's datasources point here."
  value       = module.lgtm_backends.query_endpoints
}

# --- Grafana --------------------------------------------------------------------

output "grafana_url" {
  description = "How to reach the console. ClusterIP on purpose — a second load balancer for a demo would double this layer's hourly cost."
  value       = module.grafana.port_forward_command
}

output "grafana_admin_user" {
  description = "Grafana admin username."
  value       = module.grafana.admin_user
}

output "grafana_admin_password" {
  description = "Grafana admin password. Generated, never committed. Retrieve with `terraform output -raw grafana_admin_password`."
  value       = module.grafana.admin_password
  sensitive   = true
}

output "workload_app_namespace" {
  description = "Namespace the instrumented application runs in on Cluster A."
  value       = module.workload_app.namespace
}

output "workload_app_frontend" {
  description = "Reach the storefront. The load generator drives traffic without it."
  value       = module.workload_app.frontend_port_forward
}

# The runbook's checks, rendered with this deployment's actual names so they
# can be copied and run without editing.
output "verification" {
  description = "Ready-to-run commands that prove the pipeline works end to end."
  value = {
    "1_resolve"          = "kubectl --context ${local.workload_cluster_name} -n ${var.telemetry_namespace} exec ds/alloy-agent -- nslookup ${module.gateway.gateway_dns_name}"
    "2_agent_logs"       = "kubectl --context ${local.workload_cluster_name} -n ${var.telemetry_namespace} logs -l app.kubernetes.io/name=alloy --tail=50"
    "3_agent_sent"       = "kubectl --context ${local.workload_cluster_name} -n ${var.telemetry_namespace} exec ds/alloy-agent -- wget -qO- localhost:12345/metrics | grep otelcol_exporter_send"
    "4_gateway_received" = "kubectl --context ${local.observability_cluster_name} -n ${var.telemetry_namespace} logs -l app.kubernetes.io/name=alloy --tail=50"
    "6_grafana"          = "${module.grafana.port_forward_command}  # then open http://localhost:3000"
    "5_reject_anonymous" = "kubectl --context ${local.workload_cluster_name} -n ${var.telemetry_namespace} exec ds/alloy-agent -- wget -qO- --post-data='{}' --header='Content-Type: application/json' https://${module.gateway.gateway_dns_name}:4318/v1/traces"
  }
}
