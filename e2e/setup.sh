#!/usr/bin/env bash
# Installs the platform into the current kube context: Kyverno, the tenant
# roles and priority classes, the tenancy policies, and Prometheus with
# kube-state-metrics and the tenant rules. Requires helm, kubectl, jq.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=e2e/lib.sh
source e2e/lib.sh

KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-3.9.2}"
PROMETHEUS_CHART_VERSION="${PROMETHEUS_CHART_VERSION:-29.35.0}"

log "installing Kyverno chart ${KYVERNO_CHART_VERSION}"
helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --version "$KYVERNO_CHART_VERSION" \
  --namespace kyverno --create-namespace \
  -f platform/kyverno/values.yaml \
  --wait --timeout 10m
kubectl get pods -n kyverno -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}' >&2

log "tenant roles, generator permissions, priority classes"
kubectl apply -f platform/rbac/ -f platform/scheduling/

log "tenancy policies"
# The admission webhook needs a few seconds after rollout to serve its certificate.
for attempt in $(seq 1 30); do
  kubectl apply -f platform/policies/ && break
  ((attempt == 30)) && die "Kyverno did not accept the policies"
  sleep 5
done
for p in $(kubectl get validatingpolicies.policies.kyverno.io -o name) $(kubectl get generatingpolicies.policies.kyverno.io -o name); do
  kubectl wait "$p" --for=jsonpath='{.status.conditionStatus.ready}'=true --timeout=180s >/dev/null ||
    die "policy ${p#*/} did not become ready: $(kubectl get "$p" -o jsonpath='{.status}')"
  log "policy ready: ${p#*/}"
done

log "installing Prometheus chart ${PROMETHEUS_CHART_VERSION} with kube-state-metrics"
rules_values="${RUNNER_TEMP:-/tmp}/prometheus-rules-values.yaml"
{
  echo "serverFiles:"
  echo "  alerting_rules.yml:"
  sed 's/^/    /' monitoring/rules/tenant-rules.yaml
} >"$rules_values"
helm upgrade --install prometheus prometheus-community/prometheus \
  --version "$PROMETHEUS_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  -f monitoring/prometheus-values.yaml -f "$rules_values" \
  --wait --timeout 6m

for _ in $(seq 1 60); do
  if prom_get /-/ready >/dev/null 2>&1; then
    rules=$(prom_get /api/v1/rules | jq '[.data.groups[].rules[]] | length')
    log "Prometheus ready, ${rules} rules loaded"
    [[ $rules -ge 10 ]] || die "tenant rules not loaded"
    exit 0
  fi
  sleep 3
done
die "Prometheus did not become ready"
