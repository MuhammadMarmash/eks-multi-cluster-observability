###############################################################################
# modules/lgtm-backends — Cluster B
#
# Mimir, Loki and Tempo. All three are stateless: every byte that must survive
# a pod restart lives in S3, reached through IRSA with no long-lived key
# anywhere in the cluster.
#
#   docs/adr/0010-cloud-native-storage-and-irsa.md
#
# THREE THINGS EVERY BACKEND HERE GETS RIGHT, AND EVERY DEFAULT GETS WRONG:
#
#   1. The ServiceAccount name is overridden. Each chart derives its default
#      from the Helm RELEASE name, and the IRSA trust policies were written by
#      a layer that could not know it. Without the override the pod gets no
#      role and falls back to the node role.
#
#   2. Bundled object storage is off. Mimir ships MinIO enabled by default;
#      it would silently become the durable store and everything would look
#      fine until the pod restarted.
#
#   3. No credentials appear in any config. Omitting them is what makes the
#      AWS SDK fall through to the web-identity token that IRSA projects.
#      Setting access_key_id here would DISABLE IRSA, not supplement it.
###############################################################################

locals {
  # Regional endpoint rather than the global one: a global endpoint costs an
  # extra redirect on every request and breaks if the bucket is ever moved
  # behind a VPC endpoint.
  s3_endpoint = "s3.${var.aws_region}.amazonaws.com"

  components = ["mimir", "loki", "tempo"]

  # Applied identically to all three ServiceAccounts. This annotation is the
  # entire IRSA mechanism: the EKS pod identity webhook reads it and projects a
  # web-identity token the AWS SDK then exchanges for the role.
  service_account_annotations = {
    for c in local.components :
    c => { "eks.amazonaws.com/role-arn" = var.irsa_role_arns[c] }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/part-of" = "observability-platform"
    }
  }
}
