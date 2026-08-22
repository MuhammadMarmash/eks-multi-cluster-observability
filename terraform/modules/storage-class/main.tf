###############################################################################
# modules/storage-class
#
# A default StorageClass backed by the EBS CSI driver.
#
# The EKS add-on installs the CSI *driver* but creates no StorageClass, and the
# `gp2` class EKS ships is neither default nor CSI-backed — it still names the
# in-tree kubernetes.io/aws-ebs provisioner, which is removed in current
# Kubernetes.
#
# Without a default, any PVC that omits storageClassName is created with an
# empty class and stays Pending indefinitely. The pod never schedules, and a
# Helm release with wait = true fails after its full timeout with "context
# deadline exceeded" — a message that points at time rather than at storage.
# The Mimir ingester's WAL volume is exactly such a PVC.
###############################################################################

resource "kubernetes_storage_class_v1" "this" {
  metadata {
    name = var.name

    annotations = var.make_default ? {
      "storageclass.kubernetes.io/is-default-class" = "true"
    } : {}
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = var.reclaim_policy

  # Bind only once a pod is scheduled. An EBS volume is tied to one
  # Availability Zone, so binding at claim time can place it where the pod
  # cannot follow, and the pod stays Pending with an affinity conflict.
  volume_binding_mode = "WaitForFirstConsumer"

  allow_volume_expansion = true

  parameters = {
    type      = var.volume_type
    encrypted = tostring(var.encrypted)
  }
}
