mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  namespace = "lgtm"
  datasource_urls = {
    mimir = "http://mimir-gateway.lgtm.svc.cluster.local/prometheus"
    loki  = "http://loki-gateway.lgtm.svc.cluster.local"
    tempo = "http://tempo.lgtm.svc.cluster.local:3200"
  }
  chart_repository = "oci://123456789012.dkr.ecr.eu-west-1.amazonaws.com/charts"
  image_registry   = "123456789012.dkr.ecr.eu-west-1.amazonaws.com"
  image_repository = "mirror/grafana/grafana"
}

run "grafana_is_stateless" {
  command = plan

  assert {
    condition     = output.values.persistence.enabled == false
    error_message = "Grafana must claim no PVC; dashboards are provisioned as code."
  }

  assert {
    condition     = !strcontains(output.rendered_values, "database")
    error_message = "No external database. Ephemeral SQLite in the container is the whole point of stateless."
  }
}

run "all_three_datasources_are_provisioned" {
  command = plan

  assert {
    condition     = length(output.values.datasources["datasources.yaml"].datasources) == 3
    error_message = "Mimir, Loki and Tempo must all be provisioned."
  }

  assert {
    condition     = length(setintersection(toset(output.datasource_uids), toset(["mimir", "loki", "tempo"]))) == 3
    error_message = "Datasource UIDs must be the stable ones dashboards reference."
  }
}

run "datasources_point_at_the_gateways_not_the_query_frontends" {
  command = plan

  # Mimir's nginx gateway injects the X-Scope-OrgID tenant header. Querying the
  # query-frontend directly skips it, and Mimir rejects every query.
  assert {
    condition     = strcontains(output.values.datasources["datasources.yaml"].datasources[0].url, "mimir-gateway")
    error_message = "Mimir must be queried through its gateway, which injects the tenant header."
  }

  assert {
    condition     = output.values.datasources["datasources.yaml"].datasources[0].type == "prometheus"
    error_message = "Mimir speaks the Prometheus API and must be registered as type prometheus."
  }

  assert {
    condition     = output.values.datasources["datasources.yaml"].datasources[1].type == "loki"
    error_message = "Loki datasource must be type loki."
  }

  # Single-binary Tempo serves HTTP on 3200. The distributed chart used 3100,
  # and carrying that over gives a datasource that never connects.
  assert {
    condition     = strcontains(output.values.datasources["datasources.yaml"].datasources[2].url, ":3200")
    error_message = "Single-binary Tempo serves its HTTP API on 3200, not 3100."
  }
}

run "the_three_signals_are_actually_correlated" {
  command = plan

  # Without these, Grafana is three separate tools that happen to share a login.
  assert {
    condition     = output.values.datasources["datasources.yaml"].datasources[2].jsonData.tracesToLogsV2.datasourceUid == "loki"
    error_message = "A trace must link to its logs."
  }

  assert {
    condition     = output.values.datasources["datasources.yaml"].datasources[2].jsonData.serviceMap.datasourceUid == "mimir"
    error_message = "The service map is drawn from Mimir's span metrics."
  }

  assert {
    condition     = output.values.datasources["datasources.yaml"].datasources[1].jsonData.derivedFields[0].datasourceUid == "tempo"
    error_message = "A trace ID in a log line must link to the trace."
  }
}

run "grafana_holds_no_aws_credential" {
  command = plan

  # ADR 0010: Grafana reads through the backends' HTTP APIs and never touches
  # S3. It is also the only component humans log into.
  assert {
    condition     = !strcontains(output.rendered_values, "eks.amazonaws.com/role-arn")
    error_message = "Grafana must carry no IRSA annotation."
  }

  assert {
    condition     = !strcontains(output.rendered_values, "accessKeyId")
    error_message = "Grafana must hold no AWS credential of any kind."
  }
}

run "admin_password_is_not_in_the_values" {
  command = plan

  assert {
    condition     = output.values.admin.existingSecret == "grafana-admin"
    error_message = "The password comes from a Secret, not from the values document."
  }

  assert {
    condition     = !strcontains(output.rendered_values, "adminPassword")
    error_message = "adminPassword must never appear in the rendered values; helm stores them in a release Secret readable by anyone with get access."
  }
}

run "image_comes_from_ecr_and_extras_are_off" {
  command = plan

  assert {
    condition     = !strcontains(output.rendered_values, "docker.io")
    error_message = "ADR 0005: no upstream registry in the rendered values."
  }

  assert {
    condition     = output.values.testFramework.enabled == false
    error_message = "The bats test container is an unmirrored Docker Hub image for a smoke test we do not use."
  }

  assert {
    condition     = output.values.service.type == "ClusterIP"
    error_message = "Grafana is reached by port-forward; a second load balancer would double this layer's hourly cost."
  }
}

# An empty `registry` makes the chart emit "<empty>/<repository>" — a LEADING
# SLASH and an image reference Kubernetes cannot pull. It renders fine, passes
# every values assertion, and fails as ImagePullBackOff on a live cluster.
run "image_reference_has_no_leading_slash" {
  command = plan

  assert {
    condition     = output.values.image.registry != ""
    error_message = "registry must be the ECR hostname, not empty; the chart concatenates registry and repository."
  }

  assert {
    condition     = !startswith(output.values.image.repository, "/")
    error_message = "repository must be a path within the registry, with no leading slash."
  }
}

