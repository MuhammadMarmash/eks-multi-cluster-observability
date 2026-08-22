mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  namespace  = "lgtm"
  aws_region = "eu-west-1"

  buckets = {
    mimir = "obs-platform-prod-mimir-123456789012"
    loki  = "obs-platform-prod-loki-123456789012"
    tempo = "obs-platform-prod-tempo-123456789012"
  }

  irsa_role_arns = {
    mimir = "arn:aws:iam::123456789012:role/role-obs-prod-observability-mimir-s3"
    loki  = "arn:aws:iam::123456789012:role/role-obs-prod-observability-loki-s3"
    tempo = "arn:aws:iam::123456789012:role/role-obs-prod-observability-tempo-s3"
  }

  chart_repository = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  image_registry   = "123456789012.dkr.ecr.eu-west-1.amazonaws.com"
}

# The single most important test in this module. Every chart derives its
# default ServiceAccount name from the Helm release name, and the IRSA trust
# policies were written by a layer that could not know it. If these drift, the
# pod is issued no role, falls back to the node instance role, and fails on its
# first S3 write with an opaque AccessDenied.
run "service_account_names_match_the_pinned_irsa_names" {
  command = plan

  assert {
    condition     = output.mimir_values.serviceAccount.name == "mimir-sa"
    error_message = "Mimir's ServiceAccount name must be the pinned one."
  }

  assert {
    condition     = output.loki_values.serviceAccount.name == "loki-sa"
    error_message = "Loki's ServiceAccount name must be the pinned one."
  }

  assert {
    condition     = output.tempo_values.serviceAccount.name == "tempo-sa"
    error_message = "Tempo's ServiceAccount name must be the pinned one."
  }
}

run "each_service_account_carries_its_own_role_annotation" {
  command = plan

  assert {
    condition     = output.mimir_values.serviceAccount.annotations["eks.amazonaws.com/role-arn"] == "arn:aws:iam::123456789012:role/role-obs-prod-observability-mimir-s3"
    error_message = "Mimir's ServiceAccount must carry Mimir's role ARN."
  }

  assert {
    condition     = output.loki_values.serviceAccount.annotations["eks.amazonaws.com/role-arn"] == "arn:aws:iam::123456789012:role/role-obs-prod-observability-loki-s3"
    error_message = "Loki's ServiceAccount must carry Loki's role ARN."
  }

  # Cross-wiring the annotations would give each component the wrong bucket and
  # produce AccessDenied that looks like an IAM policy bug rather than a typo.
  assert {
    condition     = output.tempo_values.serviceAccount.annotations["eks.amazonaws.com/role-arn"] == "arn:aws:iam::123456789012:role/role-obs-prod-observability-tempo-s3"
    error_message = "Tempo's ServiceAccount must carry Tempo's role ARN."
  }
}

run "bundled_object_storage_is_off" {
  command = plan

  # Mimir ships MinIO ENABLED. Left alone it silently becomes the durable
  # store, backed by a PVC, and nothing looks wrong until the pod moves.
  assert {
    condition     = output.mimir_values.minio.enabled == false
    error_message = "Mimir's bundled MinIO must be disabled."
  }

  assert {
    condition     = output.loki_values.minio.enabled == false
    error_message = "Loki's bundled MinIO must be disabled."
  }

  # The single-binary tempo chart bundles no object store at all, so the
  # assertion that matters is that its backend is not the default local disk.
  assert {
    condition     = output.tempo_values.tempo.storage.trace.backend != "local"
    error_message = "Tempo must not use the default local-disk backend."
  }
}

run "every_backend_writes_to_its_own_s3_bucket" {
  command = plan

  assert {
    condition     = output.mimir_values.mimir.structuredConfig.common.storage.backend == "s3"
    error_message = "Mimir's common storage backend must be s3."
  }

  assert {
    condition     = output.mimir_values.mimir.structuredConfig.blocks_storage.s3.bucket_name == "obs-platform-prod-mimir-123456789012"
    error_message = "Mimir blocks must land in the Mimir bucket."
  }

  assert {
    condition     = output.loki_values.loki.storage.bucketNames.chunks == "obs-platform-prod-loki-123456789012"
    error_message = "Loki chunks must land in the Loki bucket. bucketNames is required by the chart and absent from its values.yaml."
  }

  # Default is "local" — a node disk. Left alone, every trace dies with the pod.
  assert {
    condition     = output.tempo_values.tempo.storage.trace.backend == "s3"
    error_message = "Tempo's trace backend must be s3, not the default local disk."
  }

  assert {
    condition     = output.tempo_values.tempo.storage.trace.s3.bucket == "obs-platform-prod-tempo-123456789012"
    error_message = "Tempo blocks must land in the Tempo bucket."
  }
}

run "no_backend_reaches_another_backends_bucket" {
  command = plan

  assert {
    condition     = !strcontains(output.rendered_values["loki"], "obs-platform-prod-mimir-123456789012")
    error_message = "Loki's values must not name Mimir's bucket."
  }

  assert {
    condition     = !strcontains(output.rendered_values["tempo"], "obs-platform-prod-loki-123456789012")
    error_message = "Tempo's values must not name Loki's bucket."
  }

  assert {
    condition     = !strcontains(output.rendered_values["mimir"], "obs-platform-prod-tempo-123456789012")
    error_message = "Mimir's values must not name Tempo's bucket."
  }
}

# Setting a static credential does not supplement IRSA — it DISABLES it. The
# AWS SDK stops at the first credential source it finds, so an access key in
# these values silently replaces the whole web-identity mechanism.
run "no_static_credential_appears_anywhere" {
  command = plan

  assert {
    condition = alltrue([
      for v in values(output.rendered_values) :
      !strcontains(v, "accessKeyId") && !strcontains(v, "access_key_id")
    ])
    error_message = "No access key ID may appear. Its presence disables IRSA rather than supplementing it."
  }

  assert {
    condition = alltrue([
      for v in values(output.rendered_values) :
      !strcontains(v, "secretAccessKey") && !strcontains(v, "secret_access_key")
    ])
    error_message = "No secret access key may appear."
  }
}

# Every chart defaults replication_factor to 3, which is ALSO the minimum
# ingester count. Left at the default on a scaled-down cluster the ring never
# becomes healthy and every write is refused — with no error at deploy time.
run "replication_factor_is_satisfiable_by_the_ingester_count" {
  command = plan

  assert {
    condition     = output.mimir_values.mimir.structuredConfig.ingester.ring.replication_factor <= output.mimir_values.ingester.replicas
    error_message = "Mimir: replication_factor exceeds ingester replicas; the ring will never be healthy."
  }

  assert {
    condition     = output.loki_values.loki.commonConfig.replication_factor <= output.loki_values.write.replicas
    error_message = "Loki: replication_factor exceeds write replicas."
  }

  assert {
    condition     = output.tempo_values.replicas == 1
    error_message = "Tempo runs single-binary; replication factor does not apply."
  }
}

run "no_local_persistent_volumes" {
  command = plan

  # The ONE justified PVC. It holds the write-ahead log, not durable data —
  # without it a restarting ingester loses up to two hours of samples.
  assert {
    condition     = output.mimir_values.ingester.persistentVolume.enabled == true
    error_message = "Mimir's ingester needs a WAL volume; without it a restart loses everything since the last block flush."
  }

  # The chart defaults whenDeleted to Retain, which leaves EBS volumes billing
  # after a destroy. Safe to delete precisely because this is not the durable copy.
  assert {
    condition     = output.mimir_values.ingester.persistentVolume.retentionPolicy.whenDeleted == "Delete"
    error_message = "The WAL volume must be reclaimed on uninstall; the chart default of Retain orphans EBS volumes."
  }

  assert {
    condition     = output.mimir_values.ingester.persistentVolume.retentionPolicy.whenScaled == "Retain"
    error_message = "A scale-down must not discard an unflushed WAL."
  }

  assert {
    condition     = output.mimir_values.compactor.persistentVolume.enabled == false
    error_message = "Mimir compactor must not claim a PV."
  }

  # The key is volumeClaimsEnabled. `persistence.enabled` does not exist in
  # the Loki chart and is silently ignored, leaving the PVC in place.
  assert {
    condition     = output.loki_values.write.persistence.volumeClaimsEnabled == false
    error_message = "Loki write must not claim a PV — and the key is volumeClaimsEnabled, not enabled."
  }

  assert {
    condition     = output.loki_values.backend.persistence.volumeClaimsEnabled == false
    error_message = "Loki backend must not claim a PV."
  }

  # mimir-distributed 6.2.0 ships an experimental Kafka ingest path ENABLED,
  # which renders a Kafka StatefulSet with its own 5Gi PVC.
  assert {
    condition     = output.mimir_values.kafka.enabled == false
    error_message = "Mimir's bundled Kafka must be disabled; it ships enabled and brings a PVC with it."
  }

  assert {
    condition     = output.tempo_values.persistence.enabled == false
    error_message = "Tempo must not claim a PV; blocks live in S3 and the WAL is scratch."
  }
}

# Loki's chunksCache alone requests 8192Mi — an entire t3.large node, before
# Loki itself has started.
run "memory_hungry_caches_are_off_by_default" {
  command = plan

  assert {
    condition     = output.loki_values.chunksCache.enabled == false
    error_message = "Loki's chunksCache defaults to 8192Mi and must stay off on a two-node cluster."
  }

  assert {
    condition     = output.tempo_values.tempoQuery.enabled == false
    error_message = "The standalone Tempo query UI is redundant beside Grafana and costs a pod."
  }
}

run "images_resolve_to_ecr_not_upstream" {
  command = plan

  assert {
    condition = alltrue([
      for v in values(output.rendered_values) :
      !strcontains(v, "docker.io/grafana") && !strcontains(v, "quay.io")
    ])
    error_message = "ADR 0005: no upstream registry may appear in any rendered values."
  }

  assert {
    condition     = strcontains(output.mimir_values.image.repository, "123456789012.dkr.ecr.eu-west-1.amazonaws.com")
    error_message = "Mimir's image must come from ECR."
  }
}

run "loki_schema_is_supplied" {
  command = plan

  # schemaConfig is EMPTY in the chart's values.yaml and Loki will not start
  # without it. v13 + tsdb is the current pairing.
  assert {
    condition     = length(output.loki_values.loki.schemaConfig.configs) == 1
    error_message = "Loki requires an explicit schemaConfig; the chart ships an empty one."
  }

  assert {
    condition     = output.loki_values.loki.schemaConfig.configs[0].schema == "v13"
    error_message = "Loki schema must be v13."
  }

  assert {
    condition     = output.loki_values.loki.schemaConfig.configs[0].object_store == "s3"
    error_message = "Loki schema object_store must be s3."
  }
}

# The ruler sidecar pulls kiwigrid/k8s-sidecar from Docker Hub. Nothing in our
# values names that image — it comes from the chart's own defaults — so only a
# rendered-manifest check catches it. See scripts/validate-lgtm-values.sh.
run "no_unmirrored_sidecar_containers" {
  command = plan

  assert {
    condition     = output.loki_values.sidecar.rules.enabled == false
    error_message = "The Loki ruler sidecar pulls from Docker Hub and watches rules this platform does not define."
  }
}
