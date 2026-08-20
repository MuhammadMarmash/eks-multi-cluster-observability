###############################################################################
# modules/eks — outputs
#
# This is the cross-module contract. The root module wires these into
# modules/security (node SGs), into the Helm/GitOps layer (OIDC ARN for the
# LGTM IRSA roles), and into CI (kubeconfig command).
###############################################################################

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes version currently running on the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the cluster. Feed into kubeconfig or the Helm/Kubernetes providers."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group (control plane <-> nodes)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "additional_cluster_security_group_id" {
  description = "The operator-managed security group attached to the control-plane ENIs."
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "Shared security group attached to every worker node ENI."
  value       = aws_security_group.node.id
}

# --- IRSA ---------------------------------------------------------------------

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider. Required to build IRSA trust policies for Loki, Mimir, Tempo, Grafana and any application role."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL (with scheme)."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_host" {
  description = "OIDC issuer without the https:// scheme — the exact string used as the condition key prefix in IRSA trust policies."
  value       = local.oidc_issuer_host
}

# --- IAM ----------------------------------------------------------------------

output "cluster_iam_role_arn" {
  description = "ARN of the control plane IAM role."
  value       = aws_iam_role.cluster.arn
}

output "node_iam_role_arn" {
  description = "ARN of the managed node group IAM role."
  value       = aws_iam_role.node.arn
}

output "node_iam_role_name" {
  description = "Name of the managed node group IAM role."
  value       = aws_iam_role.node.name
}

output "irsa_role_arns" {
  description = "Add-on IRSA role ARNs, keyed by add-on (vpc_cni, ebs_csi)."
  value       = { for k, r in aws_iam_role.irsa : k => r.arn }
}

# --- Misc ---------------------------------------------------------------------

output "kms_key_arn" {
  description = "KMS key encrypting Kubernetes Secrets at rest."
  value       = aws_kms_key.eks.arn
}

output "node_group_arn" {
  description = "ARN of the managed node group."
  value       = aws_eks_node_group.this.arn
}

output "addon_versions" {
  description = "Installed add-on versions, keyed by add-on name."
  value = {
    "vpc-cni"            = aws_eks_addon.vpc_cni.addon_version
    "kube-proxy"         = aws_eks_addon.kube_proxy.addon_version
    "coredns"            = aws_eks_addon.coredns.addon_version
    "aws-ebs-csi-driver" = aws_eks_addon.ebs_csi_driver.addon_version
  }
}

output "kubeconfig_command" {
  description = "Ready-to-run command that writes a kubeconfig context for this cluster."
  value       = "aws eks update-kubeconfig --region ${data.aws_region.current.region} --name ${aws_eks_cluster.this.name} --alias ${aws_eks_cluster.this.name}"
}
