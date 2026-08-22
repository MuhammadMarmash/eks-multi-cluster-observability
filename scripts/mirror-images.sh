#!/usr/bin/env bash
#
# Mirror every third-party chart and image the platform layer needs into ECR.
#
# ADR 0005 forbids pulling from public registries at deploy time. This script
# is the only place a public registry is contacted, and it runs on an
# engineer's or CI runner's machine, never on a cluster.
#
# Idempotent against ECR's IMMUTABLE tag policy: a tag that already exists is
# skipped rather than re-pushed, so re-running after a partial failure is safe.
#
# Usage: AWS_REGION=eu-west-1 AWS_PROFILE=... ./scripts/mirror-images.sh
set -euo pipefail

REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# --- Pinned versions. Bump here and nowhere else. ----------------------------
# Keep in step with the defaults in terraform/envs/prod-platform/variables.tf
# and with the iam-policy.json tag in terraform/modules/aws-lb-controller.
ALLOY_CHART_VERSION="1.4.0"
ALLOY_IMAGE_TAG="v1.12.0"
ALB_CHART_VERSION="1.13.4"
ALB_IMAGE_TAG="v2.13.4"
CERT_MANAGER_VERSION="v1.19.1"

# LGTM backends. Chart versions and their appVersions move together; the image
# tag must match the chart's appVersion or the chart renders a tag that was
# never mirrored.
MIMIR_CHART_VERSION="6.2.0"
MIMIR_IMAGE_TAG="3.2.0"
LOKI_CHART_VERSION="7.3.0"
LOKI_IMAGE_TAG="3.6.12"
TEMPO_CHART_VERSION="1.24.4"
TEMPO_IMAGE_TAG="2.9.0"
ROLLOUT_OPERATOR_IMAGE_TAG="v0.31.0"
GRAFANA_CHART_VERSION="10.5.15"
GRAFANA_IMAGE_TAG="12.3.1"
METRICS_SERVER_CHART_VERSION="3.14.0"
METRICS_SERVER_IMAGE_TAG="v0.9.0"
NGINX_IMAGE_TAG="1.29-alpine"

log()  { printf '\033[36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; exit 1; }
}
require aws
require docker
require helm
docker buildx version >/dev/null 2>&1 || {
  echo "docker buildx is required (it copies multi-arch images registry-to-registry)" >&2
  exit 1
}

# Returns 0 when the tag already exists in ECR.
tag_exists() {
  local repo="$1" tag="$2"
  aws ecr describe-images \
    --region "$REGION" \
    --repository-name "$repo" \
    --image-ids "imageTag=$tag" \
    >/dev/null 2>&1
}

# Copies registry-to-registry with `docker buildx imagetools create` rather than
# pull/tag/push.
#
# pull/tag/push breaks on multi-architecture images. Docker's containerd image
# store keeps the source manifest INDEX but only the layers for the platform it
# pulled, so the push either warns that it silently dropped the other platforms
# or fails outright with "was found but does not provide any platform" — which
# names neither the cause nor the image that caused it.
#
# imagetools copies the whole index without ever materialising it locally: it is
# faster, uses no local disk, and reproduces upstream exactly.
mirror_image() {
  local src="$1" repo="$2" tag="$3"
  if tag_exists "$repo" "$tag"; then
    warn "skip ${repo}:${tag} (already present)"
    return 0
  fi
  log "image ${src} -> ${REGISTRY}/${repo}:${tag}"
  docker buildx imagetools create --tag "${REGISTRY}/${repo}:${tag}" "$src"
}

mirror_chart() {
  local chart_ref="$1" version="$2" repo="$3"
  if tag_exists "$repo" "$version"; then
    warn "skip chart ${repo}:${version} (already present)"
    return 0
  fi
  log "chart ${chart_ref}:${version} -> oci://${REGISTRY}/${repo%/*}"
  local workdir
  workdir="$(mktemp -d)"
  helm pull "$chart_ref" --version "$version" --destination "$workdir"
  helm push "$workdir"/*.tgz "oci://${REGISTRY}/${repo%/*}"
  rm -rf "$workdir"
}

log "authenticating docker and helm against ${REGISTRY}"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"
aws ecr get-login-password --region "$REGION" \
  | helm registry login --username AWS --password-stdin "$REGISTRY"

log "adding upstream chart repositories"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null

mirror_image "docker.io/grafana/alloy:${ALLOY_IMAGE_TAG}" \
             "mirror/grafana/alloy" "${ALLOY_IMAGE_TAG}"
mirror_image "public.ecr.aws/eks/aws-load-balancer-controller:${ALB_IMAGE_TAG}" \
             "mirror/eks/aws-load-balancer-controller" "${ALB_IMAGE_TAG}"

for component in controller cainjector webhook startupapicheck; do
  mirror_image "quay.io/jetstack/cert-manager-${component}:${CERT_MANAGER_VERSION}" \
               "mirror/jetstack/cert-manager-${component}" "${CERT_MANAGER_VERSION}"
done

mirror_image "docker.io/grafana/mimir:${MIMIR_IMAGE_TAG}" \
             "mirror/grafana/mimir" "${MIMIR_IMAGE_TAG}"
mirror_image "docker.io/grafana/loki:${LOKI_IMAGE_TAG}" \
             "mirror/grafana/loki" "${LOKI_IMAGE_TAG}"
mirror_image "docker.io/grafana/tempo:${TEMPO_IMAGE_TAG}" \
             "mirror/grafana/tempo" "${TEMPO_IMAGE_TAG}"
mirror_image "docker.io/grafana/rollout-operator:${ROLLOUT_OPERATOR_IMAGE_TAG}" \
             "mirror/grafana/rollout-operator" "${ROLLOUT_OPERATOR_IMAGE_TAG}"
# Note the registry: metrics-server publishes to registry.k8s.io, not Docker Hub.
mirror_image "registry.k8s.io/metrics-server/metrics-server:${METRICS_SERVER_IMAGE_TAG}" \
             "mirror/metrics-server/metrics-server" "${METRICS_SERVER_IMAGE_TAG}"
mirror_image "docker.io/grafana/grafana:${GRAFANA_IMAGE_TAG}" \
             "mirror/grafana/grafana" "${GRAFANA_IMAGE_TAG}"
mirror_image "docker.io/nginxinc/nginx-unprivileged:${NGINX_IMAGE_TAG}" \
             "mirror/nginxinc/nginx-unprivileged" "${NGINX_IMAGE_TAG}"

mirror_chart "grafana/alloy"                    "${ALLOY_CHART_VERSION}"  "charts/alloy"
mirror_chart "eks/aws-load-balancer-controller" "${ALB_CHART_VERSION}"    "charts/aws-load-balancer-controller"
mirror_chart "jetstack/cert-manager"            "${CERT_MANAGER_VERSION}" "charts/cert-manager"
mirror_chart "grafana/mimir-distributed"        "${MIMIR_CHART_VERSION}"  "charts/mimir-distributed"
mirror_chart "grafana/loki"                     "${LOKI_CHART_VERSION}"   "charts/loki"
mirror_chart "grafana/tempo"                    "${TEMPO_CHART_VERSION}"  "charts/tempo"
mirror_chart "grafana/grafana"                  "${GRAFANA_CHART_VERSION}" "charts/grafana"
mirror_chart "metrics-server/metrics-server"    "${METRICS_SERVER_CHART_VERSION}" "charts/metrics-server"

log "done. registry: ${REGISTRY}"
