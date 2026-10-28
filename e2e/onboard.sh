#!/usr/bin/env bash
# Onboards every tenant in tenants/ exactly as the platform team would
# (kubectl apply of the tenant file), then waits until tenant-onboarding has
# created the full set of objects in each namespace. Records how long it took.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=e2e/lib.sh
source e2e/lib.sh

start=$(now_ms)
kubectl apply -f tenants/
for ns in "${TENANT_NAMESPACES[@]}"; do
  wait_for 180 fully_onboarded "$ns" || {
    kubectl get rolebindings,resourcequotas,limitranges,networkpolicies -n "$ns" >&2 || true
    kubectl get updaterequests -n kyverno -o wide >&2 || true
    die "${ns}: only $(object_count "$ns")/${OBJECTS_PER_NAMESPACE} tenant objects created"
  }
done
elapsed=$(($(now_ms) - start))
log "3 tenant namespaces fully onboarded in ${elapsed} ms"

for ns in "${TENANT_NAMESPACES[@]}"; do
  log "${ns}: $(kubectl get resourcequota tenant-quota -n "$ns" -o jsonpath='{.spec.hard}')"
done
kubectl get rolebindings,resourcequotas,limitranges,networkpolicies -n team-b-apps -o wide >&2

jq -n --argjson ms "$elapsed" --argjson n "${#TENANT_NAMESPACES[@]}" \
  '{namespaces:$n, objects_per_namespace:9, initial_onboarding_ms:$ms}' >"${RESULTS_DIR}/onboarding.json"
