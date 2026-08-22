###############################################################################
# modules/storage-class — input variables
###############################################################################

variable "name" {
  description = "StorageClass name."
  type        = string
  default     = "gp3"
}

variable "make_default" {
  description = <<-EOT
    Mark this the cluster's default StorageClass.

    EKS ships a `gp2` class but does NOT mark it default, and it still uses the
    in-tree kubernetes.io/aws-ebs provisioner. With no default, a PVC that names
    no storageClassName is created with an empty class and stays Pending
    forever — the pod never starts and a Helm release with wait = true times out
    with "context deadline exceeded", which says nothing about storage.
  EOT
  type        = bool
  default     = true
}

variable "volume_type" {
  description = "EBS volume type. gp3 is cheaper than gp2 per GiB and decouples IOPS from size."
  type        = string
  default     = "gp3"
}

variable "encrypted" {
  description = "Encrypt volumes at rest. No reason not to; EBS encryption is free."
  type        = bool
  default     = true
}

variable "reclaim_policy" {
  description = "What happens to the volume when its PVC is deleted. Delete is right for scratch such as an ingester WAL, whose durable copy is in S3."
  type        = string
  default     = "Delete"
}
