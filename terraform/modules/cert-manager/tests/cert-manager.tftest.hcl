mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  chart_repository = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  chart_version    = "v1.19.1"
  image_registry   = "123456789012.dkr.ecr.eu-west-1.amazonaws.com"
}

run "installs_crds_with_the_chart" {
  command = plan

  assert {
    condition     = output.values.crds.enabled == true
    error_message = "The CRDs must ship with the release. Installing them separately means a destroy leaves orphaned Certificates behind."
  }
}

run "every_component_image_comes_from_ecr" {
  command = plan

  assert {
    condition     = output.values.image.repository == "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mirror/jetstack/cert-manager-controller"
    error_message = "Controller image must resolve to ECR."
  }

  assert {
    condition     = output.values.cainjector.image.repository == "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mirror/jetstack/cert-manager-cainjector"
    error_message = "cainjector image must resolve to ECR."
  }

  assert {
    condition     = output.values.webhook.image.repository == "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mirror/jetstack/cert-manager-webhook"
    error_message = "webhook image must resolve to ECR."
  }

  assert {
    condition     = output.values.startupapicheck.image.repository == "123456789012.dkr.ecr.eu-west-1.amazonaws.com/mirror/jetstack/cert-manager-startupapicheck"
    error_message = "startupapicheck image must resolve to ECR. It is easy to forget and it is the one that blocks the release from ever reporting ready."
  }

  assert {
    condition     = !strcontains(output.rendered_values, "quay.io")
    error_message = "No upstream registry may appear in the rendered values."
  }
}

run "terraform_owns_the_namespace" {
  command = plan

  assert {
    condition     = kubernetes_namespace_v1.this.metadata[0].name == "cert-manager"
    error_message = "The namespace is a Terraform resource."
  }

  assert {
    condition     = helm_release.this.create_namespace == false
    error_message = "The chart must not create its own namespace."
  }
}

run "release_waits_for_readiness" {
  command = plan

  assert {
    condition     = helm_release.this.wait == true
    error_message = "Reading the CA secret in the next module races cert-manager unless this release blocks until its webhook is serving."
  }
}
