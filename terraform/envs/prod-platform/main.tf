###############################################################################
# envs/prod-platform — the Kubernetes layer
#
#   dns-private-zone    x1  -> observability.internal, both VPCs
#   aws-lb-controller   x1  -> Cluster B, so a Service can become an NLB
#   cert-manager        x1  -> Cluster B, issues the gateway certificate
#   telemetry-gateway   x1  -> Cluster B, TLS + auth + fan-out
#   telemetry-agent     x1  -> Cluster A, collects and ships
#
# Modules never call each other. This file is the only place the two clusters
# meet, and it is the only place that knows the gateway's name, CA and
# credential travel from B to A.
#
# Design rationale:
#   docs/superpowers/specs/2026-08-21-cross-cluster-telemetry-pipeline-design.md
#   docs/adr/0006  Alloy as the unified agent
#   docs/adr/0007  internal NLB plus a dual-associated private zone
#   docs/adr/0008  two-stage Terraform
###############################################################################

###############################################################################
# 1. NAME RESOLUTION
#
# Associated with BOTH VPCs. Without the workload association, a query from
# Cluster A leaks past the VPC resolver and returns NXDOMAIN — the single most
# likely way this pipeline fails to come up.
###############################################################################

module "dns" {
  source = "../../modules/dns-private-zone"

  zone_name      = var.private_zone_name
  primary_vpc_id = local.infra.clusters.observability.vpc_id
  additional_vpc_ids = [
    local.infra.clusters.workload.vpc_id,
  ]

  tags = local.common_tags
}

###############################################################################
# 2. CLUSTER B ADD-ONS
###############################################################################

module "lb_controller" {
  source = "../../modules/aws-lb-controller"

  providers = {
    helm = helm.observability
  }

  cluster_name       = local.observability_cluster_name
  vpc_id             = local.infra.clusters.observability.vpc_id
  region             = var.aws_region
  oidc_provider_arn  = local.infra.clusters.observability.oidc_provider_arn
  oidc_provider_host = local.observability_oidc_host

  chart_repository = local.chart_registry
  chart_version    = var.alb_chart_version
  image_repository = "${local.registry}/mirror/eks/aws-load-balancer-controller"
  image_tag        = var.alb_image_tag

  tags = local.common_tags
}

module "cert_manager" {
  source = "../../modules/cert-manager"

  providers = {
    helm       = helm.observability
    kubernetes = kubernetes.observability
  }

  chart_repository = local.chart_registry
  chart_version    = var.cert_manager_version
  image_registry   = local.registry
}

###############################################################################
# 3. THE GATEWAY — Cluster B
#
# Depends on both add-ons: the controller has to exist before a Service of type
# LoadBalancer reconciles into anything, and cert-manager has to be serving
# before a Certificate is admitted.
###############################################################################

module "gateway" {
  source = "../../modules/telemetry-gateway"

  providers = {
    helm       = helm.observability
    kubernetes = kubernetes.observability
  }

  cluster_name     = local.observability_cluster_name
  namespace        = var.telemetry_namespace
  gateway_dns_name = local.gateway_dns_name
  route53_zone_id  = module.dns.zone_id

  cert_manager_namespace = module.cert_manager.namespace

  nlb_subnet_ids = data.terraform_remote_state.infra.outputs.observability_private_subnet_ids

  # The group modules/security already builds. Putting it on the load balancer
  # is what gives the workload-VPC CIDR restriction teeth.
  nlb_security_group_ids = [
    data.terraform_remote_state.infra.outputs.otlp_security_group_ids.observability_ingress,
  ]

  chart_repository = local.chart_registry
  chart_version    = var.alloy_chart_version
  image_repository = "${local.registry}/mirror/grafana/alloy"
  image_tag        = var.alloy_image_tag

  replicas = var.gateway_replicas

  lgtm_enabled   = var.lgtm_enabled
  mimir_endpoint = var.mimir_endpoint
  loki_endpoint  = var.loki_endpoint
  tempo_endpoint = var.tempo_endpoint

  tags = local.common_tags

  depends_on = [
    module.lb_controller,
    module.cert_manager,
  ]
}

###############################################################################
# 4. THE AGENT — Cluster A
#
# Everything Cluster A learns about Cluster B passes through here: a name, a CA
# and a credential. The agent module itself has no knowledge of the other
# cluster at all.
###############################################################################

module "agent" {
  source = "../../modules/telemetry-agent"

  providers = {
    helm       = helm.workload
    kubernetes = kubernetes.workload
  }

  cluster_name = local.workload_cluster_name
  namespace    = var.telemetry_namespace

  gateway_endpoint = module.gateway.gateway_endpoint
  gateway_ca_pem   = module.gateway.ca_certificate_pem
  ingest_username  = module.gateway.ingest_username
  ingest_password  = module.gateway.ingest_password

  chart_repository = local.chart_registry
  chart_version    = var.alloy_chart_version
  image_repository = "${local.registry}/mirror/grafana/alloy"
  image_tag        = var.alloy_image_tag

  scrape_interval = var.scrape_interval
}
