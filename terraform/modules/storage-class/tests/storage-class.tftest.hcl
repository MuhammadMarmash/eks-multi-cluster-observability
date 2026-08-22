mock_provider "kubernetes" {}

run "is_the_cluster_default_and_csi_backed" {
  command = plan

  # Without a default, a PVC that omits storageClassName stays Pending forever
  # and the Helm release that owns it times out with a message about deadlines
  # rather than about storage.
  assert {
    condition     = kubernetes_storage_class_v1.this.metadata[0].annotations["storageclass.kubernetes.io/is-default-class"] == "true"
    error_message = "EKS marks no StorageClass default, so this one must be."
  }

  # The gp2 class EKS ships names the in-tree provisioner, which is removed in
  # current Kubernetes.
  assert {
    condition     = kubernetes_storage_class_v1.this.storage_provisioner == "ebs.csi.aws.com"
    error_message = "Must use the EBS CSI driver, not the removed in-tree provisioner."
  }
}

run "volumes_are_encrypted_and_bound_where_the_pod_lands" {
  command = plan

  assert {
    condition     = kubernetes_storage_class_v1.this.parameters["encrypted"] == "true"
    error_message = "EBS encryption is free; there is no reason to leave it off."
  }

  # An EBS volume lives in one AZ. Binding at claim time can place it where the
  # pod cannot be scheduled, and the pod stays Pending on an affinity conflict.
  assert {
    condition     = kubernetes_storage_class_v1.this.volume_binding_mode == "WaitForFirstConsumer"
    error_message = "Immediate binding places the volume before the scheduler picks an AZ."
  }
}
