###############################################################################
# envs/prod-platform — the Kubernetes layer
#
#   dns-private-zone    x1  -> observability.internal, both VPCs
#   aws-lb-controller   x1  -> Cluster B, so a Service can become an NLB
#   cert-manager        x1  -> Cluster B, issues the gateway certificate
#   telemetry-gateway   x1  -> Cluster B, TLS + auth + fan-out
#   telemetry-agent     x1  -> Cluster A, collects and ships
#   lgtm-backends       x1  -> Cluster B, Mimir + Loki + Tempo on S3
#   grafana             x1  -> Cluster B, the single pane of glass
#   metrics-server      x2  -> BOTH clusters, so an HPA can function at all
#   storage-class       x2  -> BOTH clusters, a CSI-backed default for PVCs
#   workload-app        x1  -> Cluster A, the instrumented application
#
# Modules never call each other. This file is the only place the two clusters
# meet, and it is the only place that knows the gateway's name, CA and
# credential travel from B to A.
#
# Design rationale:
#   docs/adr/0006  Alloy as the unified agent
#   docs/adr/0007  internal NLB plus a dual-associated private zone
#   docs/adr/0008  two-stage Terraform
#   docs/adr/0010  S3 object storage and the IRSA model that reaches it
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

  # Belt and braces alongside disabling the Service mutator webhook. If that
  # webhook is ever re-enabled, anything creating a Service must not race the
  # controller becoming ready.
  depends_on = [module.lb_controller]
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
  image_registry   = local.registry
  image_repository = "mirror/grafana/alloy"
  image_tag        = var.alloy_image_tag

  replicas = var.gateway_replicas

  # The fan-out targets come from the backends themselves rather than from
  # variables, so a service rename cannot silently leave the gateway writing
  # into the void. Tempo's endpoint in particular changed when it moved to the
  # single-binary chart.
  lgtm_enabled   = var.lgtm_enabled
  mimir_endpoint = module.lgtm_backends.mimir_otlp_endpoint
  loki_endpoint  = module.lgtm_backends.loki_otlp_endpoint
  tempo_endpoint = module.lgtm_backends.tempo_otlp_endpoint

  tags = local.common_tags

  depends_on = [
    module.lb_controller,
    module.cert_manager,
    # Not strictly required — Alloy retries a refused exporter — but it keeps a
    # first apply from filling the gateway's logs with connection errors while
    # the backends are still coming up.
    module.lgtm_backends,
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
  image_registry   = local.registry
  image_repository = "mirror/grafana/alloy"
  image_tag        = var.alloy_image_tag

  scrape_interval = var.scrape_interval
}

###############################################################################
# 5. THE BACKENDS — Cluster B
#
# Mimir, Loki and Tempo. Stateless: everything durable is in the S3 buckets
# envs/prod created, reached through the IRSA roles it created alongside them.
#
# The bucket names, role ARNs and ServiceAccount names all come from that
# state. The ServiceAccount names in particular are NOT chosen here — the trust
# policies are pinned to them, and each chart's own default derives from the
# Helm release name instead.
#
#   docs/adr/0010-cloud-native-storage-and-irsa.md
###############################################################################

module "lgtm_backends" {
  source = "../../modules/lgtm-backends"

  providers = {
    helm       = helm.observability
    kubernetes = kubernetes.observability
  }

  namespace  = data.terraform_remote_state.infra.outputs.lgtm_namespace
  aws_region = var.aws_region

  buckets        = data.terraform_remote_state.infra.outputs.lgtm_bucket_names
  irsa_role_arns = data.terraform_remote_state.infra.outputs.lgtm_irsa_role_arns

  chart_repository = local.chart_registry
  image_registry   = local.registry

  mimir_chart_version = var.mimir_chart_version
  loki_chart_version  = var.loki_chart_version
  tempo_chart_version = var.tempo_chart_version

  replication_factor = var.lgtm_replication_factor
  ingester_replicas  = var.lgtm_ingester_replicas
  enable_caches      = var.lgtm_enable_caches

  # Services need the controller; the Mimir ingester's WAL volume needs a
  # default StorageClass to bind against.
  depends_on = [
    module.lb_controller,
    module.storage_class_observability,
  ]
}

###############################################################################
# 6. GRAFANA — Cluster B
#
# Shares the LGTM namespace, which is why it does not create it. Reads through
# the three backends' HTTP APIs and holds no AWS credential of any kind.
#
# Mimir and Loki are queried through their nginx gateways rather than their
# query-frontends: the Mimir gateway injects the X-Scope-OrgID tenant header,
# without which Mimir rejects every query.
###############################################################################

module "grafana" {
  source = "../../modules/grafana"

  providers = {
    helm       = helm.observability
    kubernetes = kubernetes.observability
  }

  namespace        = module.lgtm_backends.namespace
  create_namespace = false # lgtm-backends owns it

  datasource_urls = module.lgtm_backends.query_endpoints

  chart_repository = local.chart_registry
  chart_version    = var.grafana_chart_version
  image_registry   = local.registry
  image_repository = "mirror/grafana/grafana"
  image_tag        = var.grafana_image_tag

  depends_on = [module.lgtm_backends]
}

###############################################################################
# 7. METRICS SERVER — both clusters
#
# The resource metrics API. An HPA without it does not degrade, it never
# functions: it reports `<unknown>` for its target forever.
#
# On both clusters because both need it — Cluster A for the workload app, Cluster B
# for the Mimir ingester autoscaling in docs/runbooks/day-2-ops.md.
###############################################################################

module "metrics_server_workload" {
  source = "../../modules/metrics-server"

  providers = {
    helm = helm.workload
  }

  cluster_name     = local.workload_cluster_name
  chart_repository = local.chart_registry
  chart_version    = var.metrics_server_chart_version
  image_registry   = local.registry
  image_tag        = var.metrics_server_image_tag
}

module "metrics_server_observability" {
  source = "../../modules/metrics-server"

  providers = {
    helm = helm.observability
  }

  cluster_name     = local.observability_cluster_name
  chart_repository = local.chart_registry
  chart_version    = var.metrics_server_chart_version
  image_registry   = local.registry
  image_tag        = var.metrics_server_image_tag
}

###############################################################################
# 8. DEFAULT STORAGE CLASS — both clusters
#
# The EBS CSI add-on installs the driver but creates no StorageClass, and the
# gp2 class EKS ships is neither default nor CSI-backed. Without a default, any
# PVC omitting storageClassName stays Pending forever — which is what stalled
# the Mimir ingester's WAL volume and timed out its Helm release.
###############################################################################

module "storage_class_workload" {
  source = "../../modules/storage-class"

  providers = {
    kubernetes = kubernetes.workload
  }
}

module "storage_class_observability" {
  source = "../../modules/storage-class"

  providers = {
    kubernetes = kubernetes.observability
  }
}

###############################################################################
# 9. THE WORKLOAD APPLICATION — Cluster A
#
# The thing the platform exists to observe. Without it the agent has kubelet
# metrics and pod logs to ship and no traces at all.
#
# It talks to the Alloy agent beside it and knows nothing about Cluster B, the
# peering link or the gateway. That is the whole point of the agent: the
# application exports OTLP to localhost-ish and the platform does the rest.
#
#   docs/adr/0009-workload-application-source.md
###############################################################################

module "workload_app" {
  source = "../../modules/workload-app"

  providers = {
    helm       = helm.workload
    kubernetes = kubernetes.workload
  }

  namespace = var.workload_app_namespace

  # Host only — the chart appends the port.
  agent_otlp_endpoint = "alloy-agent.${var.telemetry_namespace}.svc.cluster.local"

  chart_repository = local.chart_registry
  chart_version    = var.otel_demo_chart_version
  image_registry   = local.registry
  app_version      = var.otel_demo_version

  depends_on = [module.agent]
}
