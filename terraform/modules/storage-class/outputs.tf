###############################################################################
# modules/storage-class — outputs
###############################################################################

output "name" {
  description = "StorageClass name. Depend on this from anything that creates a PVC."
  value       = kubernetes_storage_class_v1.this.metadata[0].name
}

output "is_default" {
  description = "Whether this class is annotated as the cluster default."
  value       = var.make_default
}
