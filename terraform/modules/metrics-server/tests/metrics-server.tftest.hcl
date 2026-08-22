mock_provider "helm" {}

variables {
  cluster_name     = "obs-platform-prod-observability"
  chart_repository = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  image_registry   = "123456789012.dkr.ecr.eu-west-1.amazonaws.com"
}

run "image_comes_from_ecr_with_no_leading_slash" {
  command = plan

  assert {
    condition     = !startswith(output.values.image.repository, "/")
    error_message = "An empty registry produces a leading slash and an unpullable reference."
  }

  assert {
    condition     = startswith(output.values.image.repository, "123456789012.dkr.ecr.eu-west-1.amazonaws.com/")
    error_message = "ADR 0005: the image must resolve to ECR."
  }

  assert {
    condition     = !strcontains(output.rendered_values, "registry.k8s.io")
    error_message = "No upstream registry may appear in the rendered values."
  }
}

run "kubelet_scrape_tolerates_the_per_node_ca" {
  command = plan

  # EKS kubelets serve certificates signed by a per-node CA the cluster bundle
  # does not carry. Without this flag every scrape fails x509 verification and
  # metrics-server reports no metrics at all, which looks like a broken HPA.
  assert {
    condition     = contains(output.values.args, "--kubelet-insecure-tls")
    error_message = "metrics-server cannot verify EKS kubelet certificates against the cluster CA; without this flag it collects nothing."
  }
}

run "installs_into_an_existing_namespace" {
  command = plan

  assert {
    condition     = helm_release.this.create_namespace == false
    error_message = "kube-system is created by Kubernetes; the chart must not try to own it."
  }

  assert {
    condition     = helm_release.this.wait == true
    error_message = "An HPA created in the same apply needs the metrics API to be serving."
  }
}
