#!/usr/bin/env bash
# Checks per-tenant visibility against the live Prometheus: every tenant
# namespace is attributed to its tenant, and every query in the Grafana
# dashboard (monitoring/dashboards/tenant-usage.json) returns data. Run by
# e2e/fairshare.sh while team-b is at its quota, so the alert panel has data.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=e2e/lib.sh
source e2e/lib.sh

DASHBOARD=monitoring/dashboards/tenant-usage.json

attributed=$(prom_series 'namespace_tenant:info')
log "namespaces attributed to a tenant: ${attributed}"
((attributed >= ${#TENANT_NAMESPACES[@]})) || die "expected ${#TENANT_NAMESPACES[@]} tenant namespaces in namespace_tenant:info"

rows=()
empty=0
while IFS=$'\t' read -r panel expr; do
  q=${expr//\$tenant/.+}
  n=$(prom_series "$q")
  log "panel \"${panel}\": ${n} series for ${q}"
  ((n > 0)) || empty=$((empty + 1))
  rows+=("$(jq -cn --arg p "$panel" --arg e "$expr" --argjson n "$n" '{panel:$p, expr:$e, series:$n}')")
done < <(jq -r '.panels[] | .title as $t | .targets[] | [$t, .expr] | @tsv' "$DASHBOARD")

tenants=$(prom_get "/api/v1/query?query=$(jq -rn --arg q 'tenant:pods:count' '$q|@uri')" |
  jq -c '[.data.result[] | {tenant:.metric.tenant, pods:(.value[1]|tonumber)}]')
log "pods per tenant: ${tenants}"

printf '%s\n' "${rows[@]}" | jq -s --argjson t "$tenants" --argjson a "$attributed" \
  '{tenant_namespaces:$a, pods_per_tenant:$t, dashboard_queries:.}' >"${RESULTS_DIR}/monitoring.json"

((empty == 0)) || die "${empty} dashboard queries returned no data"
