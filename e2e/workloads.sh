#!/usr/bin/env bash
# Each tenant admin deploys its own applications with its own identity (the
# platform only deploys the probe in a non-tenant namespace), then waits for
# them to become ready.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=e2e/lib.sh
source e2e/lib.sh

as a-admin apply -f conformance/manifests/workloads-team-a.yaml
as b-admin apply -f conformance/manifests/workloads-team-b.yaml
as platform apply -f conformance/manifests/probe-platform.yaml

for target in team-a-backend/echo team-a-frontend/client team-b-apps/echo team-b-apps/client platform-probe/client; do
  ns=${target%%/*} deploy=${target##*/}
  kubectl -n "$ns" rollout status "deploy/${deploy}" --timeout=180s
done
kubectl get pods -A -l app.kubernetes.io/name -o wide >&2 || true
for ns in "${TENANT_NAMESPACES[@]}"; do
  log "${ns} quota used: $(kubectl get resourcequota tenant-quota -n "$ns" -o jsonpath='{.status.used}')"
done
