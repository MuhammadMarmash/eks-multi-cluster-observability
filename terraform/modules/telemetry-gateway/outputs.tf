###############################################################################
# modules/telemetry-gateway — outputs
#
# This is the contract the agent side consumes. Everything Cluster A needs to
# know about Cluster B is here: a name, a CA, and a credential.
###############################################################################

output "namespace" {
  description = "Namespace the gateway runs in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "gateway_endpoint" {
  description = "host:port the agent exports to."
  value       = "${var.gateway_dns_name}:4317"
}

output "gateway_dns_name" {
  description = "Fully qualified name of the gateway, matching the certificate SAN."
  value       = var.gateway_dns_name
}

output "nlb_hostname" {
  description = "AWS-generated name of the internal NLB. Useful when diagnosing whether a resolution failure is Route 53 or the load balancer."
  value       = kubernetes_service_v1.gateway.status[0].load_balancer[0].ingress[0].hostname
}

# The provider marks a Secret's whole `data` map sensitive, and rightly so —
# that map also holds the CA's PRIVATE key. Only the public certificate is
# pulled out here, and only that is un-marked: a CA certificate is public by
# definition, and being able to print it is what lets an operator compare the
# CA on Cluster A against the one on Cluster B when a handshake fails on the
# SAN. See docs/RUNBOOK-telemetry.md.
output "ca_certificate_pem" {
  description = "PEM of the CA that signed the gateway certificate. Feed to the agent so it can verify for real."
  value       = nonsensitive(lookup(data.kubernetes_secret_v1.ca.data, "ca.crt", ""))
}

output "ingest_username" {
  description = "Username the agent authenticates with."
  value       = local.ingest_username
}

output "ingest_password" {
  description = "Password the agent authenticates with."
  value       = random_password.ingest.result
  sensitive   = true
}

output "values" {
  description = "The Helm values as a structured map. Assert against this rather than the rendered string; yamlencode quotes every key."
  value       = local.values
}

output "rendered_config" {
  description = "The rendered .alloy config. Exposed so tests can assert on TLS, auth and exporter routing without an apply."
  value       = local.config
}

output "rendered_values" {
  description = "The values document handed to Helm."
  value       = yamlencode(local.values)
}
