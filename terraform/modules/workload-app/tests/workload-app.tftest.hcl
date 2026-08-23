mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  namespace           = "boutique"
  agent_otlp_endpoint = "alloy-agent.telemetry.svc.cluster.local"
  chart_repository    = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  image_registry      = "123456789012.dkr.ecr.eu-west-1.amazonaws.com"
}

# The whole integration. Every service builds its OTLP endpoint from this one
# variable; get it wrong and the application runs perfectly while emitting
# telemetry into the void.
run "services_send_to_the_local_alloy_agent" {
  command = plan

  assert {
    condition     = length([for e in output.values.default.env : e if e.name == "OTEL_COLLECTOR_NAME" && e.value == "alloy-agent.telemetry.svc.cluster.local"]) == 1
    error_message = "OTEL_COLLECTOR_NAME must point at the Alloy agent on this cluster."
  }

  # The application must know nothing about Cluster B — the agent is the only
  # thing that does.
  assert {
    condition     = !strcontains(output.rendered_values, "observability.internal")
    error_message = "The application must not reference the cross-cluster gateway; it talks to the local agent only."
  }
}

run "the_demos_own_observability_stack_is_off" {
  command = plan

  # Deploying Jaeger, Prometheus, Grafana and OpenSearch beside a platform
  # built to do exactly that would be both redundant and unschedulable.
  assert {
    condition = alltrue([
      output.values.jaeger.enabled == false,
      output.values.prometheus.enabled == false,
      output.values.grafana.enabled == false,
      output.values.opensearch.enabled == false,
      output.values["opentelemetry-collector"].enabled == false,
    ])
    error_message = "The chart's bundled observability stack is redundant here and must be disabled."
  }
}

run "images_come_from_ecr" {
  command = plan

  assert {
    condition     = startswith(output.values.default.image.repository, "123456789012.dkr.ecr.eu-west-1.amazonaws.com/")
    error_message = "ADR 0005: service images must resolve to ECR."
  }

  assert {
    condition     = !strcontains(output.rendered_values, "ghcr.io")
    error_message = "No upstream registry may appear in the rendered values."
  }
}

# Sixteen services on two nodes will have pods pending while others schedule.
# Rolling the release back for that would mean never converging.
run "release_does_not_roll_itself_back_while_converging" {
  command = plan

  assert {
    condition     = helm_release.this.atomic == false
    error_message = "An atomic release would uninstall the whole application the first time one service is slow to schedule."
  }
}
