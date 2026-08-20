###############################################################################
# modules/eks
#
# One EKS cluster + one managed node group in private subnets. Instantiated
# twice:
#   * eks-workload      (Cluster A) — Google Online Boutique + OTel collectors
#   * eks-observability (Cluster B) — Loki / Grafana / Tempo / Mimir
#
# Security posture — private nodes, IRSA-only credentials, thin node role,
# closed IMDS, envelope-encrypted secrets:
#   docs/adr/0004-cluster-security-posture.md
###############################################################################

locals {
  tags = merge(
    var.tags,
    {
      "Cluster"   = var.cluster_name
      "Module"    = "eks"
      "ManagedBy" = "terraform"
    },
  )

  # OIDC issuer URL without the scheme — the form IAM trust policies expect.
  oidc_issuer_host = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

###############################################################################
# Envelope encryption for Kubernetes Secrets (see ADR 0004)
###############################################################################

resource "aws_kms_key" "eks" {
  description             = "Envelope encryption key for ${var.cluster_name} Kubernetes secrets"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true

  tags = merge(local.tags, { "Name" = "kms-${var.cluster_name}-secrets" })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/eks/${var.cluster_name}"
  target_key_id = aws_kms_key.eks.key_id
}

###############################################################################
# Control-plane logging
#
# Created explicitly (rather than letting EKS create it implicitly) so that
# retention and tags are managed, and so `terraform destroy` cleans it up.
###############################################################################

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  tags = merge(local.tags, { "Name" = "log-${var.cluster_name}-control-plane" })
}

###############################################################################
# Additional cluster security group
#
# EKS creates its own "cluster security group" for control-plane <-> node
# traffic. This extra SG is attached to the control-plane ENIs so that
# operator-defined rules can be expressed without touching the AWS-managed one.
###############################################################################

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-control-plane-sg"
  description = "Additional control plane security group for ${var.cluster_name}"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { "Name" = "${var.cluster_name}-control-plane-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  description       = "Control plane egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

###############################################################################
# The cluster
###############################################################################

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # We manage vpc-cni / kube-proxy / coredns as *managed add-ons* (see
  # addons.tf), so the self-managed bootstrap copies are not installed.
  # Changing this value forces cluster replacement.
  bootstrap_self_managed_addons = false

  vpc_config {
    # PRIVATE SUBNETS ONLY. The control-plane cross-account ENIs and every node
    # live here; nothing in this cluster is directly reachable from the
    # internet.
    subnet_ids              = var.private_subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  access_config {
    authentication_mode                         = var.authentication_mode
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = var.enabled_cluster_log_types

  kubernetes_network_config {
    ip_family = "ipv4"
  }

  upgrade_policy {
    # STANDARD keeps the cluster on the supported-version treadmill instead of
    # silently rolling into (billable) extended support. The Day-2 upgrade
    # runbook depends on this being visible.
    support_type = "STANDARD"
  }

  tags = merge(local.tags, { "Name" = var.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]

  timeouts {
    create = "45m"
    update = "60m"
    delete = "30m"
  }
}

###############################################################################
# IRSA — IAM OIDC identity provider
#
# Turns the cluster's OIDC issuer into an IAM identity provider so a
# ServiceAccount token can be exchanged for scoped AWS credentials. Every
# "no long-lived access keys" claim in this architecture rests on it.
###############################################################################

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(local.tags, { "Name" = "oidc-${var.cluster_name}" })
}

###############################################################################
# Access entries (IAM-native RBAC bootstrap)
###############################################################################

resource "aws_eks_access_entry" "this" {
  for_each = var.access_entries

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.principal_arn
  type              = each.value.type
  kubernetes_groups = length(each.value.kubernetes_groups) > 0 ? each.value.kubernetes_groups : null

  tags = local.tags
}

resource "aws_eks_access_policy_association" "this" {
  for_each = { for k, v in var.access_entries : k => v if v.policy_arn != null }

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = each.value.access_scope.type
    namespaces = each.value.access_scope.type == "namespace" ? each.value.access_scope.namespaces : null
  }

  depends_on = [aws_eks_access_entry.this]
}
