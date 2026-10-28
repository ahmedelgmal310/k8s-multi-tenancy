#!/usr/bin/env bash
# Builds e2e-results/summary.md from the JSON results of this run and appends
# it to the GitHub job summary when running in Actions.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=e2e/lib.sh
source e2e/lib.sh

r="$RESULTS_DIR"
{
  echo "## Tenancy conformance matrix"
  echo
  if [[ -f $r/conformance.json ]]; then
    jq -r '"**\(.total - .failures)/\(.total)** cases matched the expected result (" +
      ([.cases[] | .expected] | group_by(.) | map("\(.[0]) \(length)") | join(", ")) + ")."' "$r/conformance.json"
    echo
    cat "$r/conformance.md"
  fi
  if [[ -f $r/identities.json ]]; then
    echo
    echo "## Test identities (client certificates created in this run)"
    echo
    echo "| Identity | User | Groups | Certificate valid until |"
    echo "|---|---|---|---|"
    jq -r '.[] | "| `\(.identity)` | \(.user) | \(.groups | map(select(. != "system:authenticated")) | join(", ")) | \(.cert_not_after) |"' "$r/identities.json"
  fi
  if [[ -f $r/fairshare.json ]]; then
    echo
    echo "## Fair share: noisy neighbour"
    echo
    jq -r '"team-b asked for **\(.noisy.requested_replicas)** CPU-burning replicas; quota admitted **\(.noisy.admitted_replicas)** and rejected \(.noisy.quota_rejections) pod creations. team-b CPU while burning: \(.prometheus.team_b_cpu_cores) cores (limit quota 2). `TenantQuotaNearLimit` for team-b: \(.prometheus.quota_near_limit_alert_team_b).\n\n| team-a frontend -> backend (\(.requests_per_probe) requests) | ok | failed | p50 | p95 | p99 | max |\n|---|---|---|---|---|---|---|\n| before | \(.team_a_latency.before.ok) | \(.team_a_latency.before.failed) | \(.team_a_latency.before.p50_ms) ms | \(.team_a_latency.before.p95_ms) ms | \(.team_a_latency.before.p99_ms) ms | \(.team_a_latency.before.max_ms) ms |\n| during | \(.team_a_latency.during.ok) | \(.team_a_latency.during.failed) | \(.team_a_latency.during.p50_ms) ms | \(.team_a_latency.during.p95_ms) ms | \(.team_a_latency.during.p99_ms) ms | \(.team_a_latency.during.max_ms) ms |\n\nteam-a pods ready/total and restarts: before `\(.team_a_health.before)`, during `\(.team_a_health.during)`.\n\nExample rejection: `\(.noisy.example_rejection)`"' "$r/fairshare.json"
  fi
  if [[ -f $r/monitoring.json ]]; then
    echo
    echo "## Per-tenant visibility"
    echo
    jq -r '"Tenant namespaces attributed: \(.tenant_namespaces). Pods per tenant: \(.pods_per_tenant | map("\(.tenant)=\(.pods)") | join(", ")).\n\n| Dashboard panel | Query | Series |\n|---|---|---|\n" + (.dashboard_queries | map("| \(.panel) | `\(.expr | gsub("\\|"; "\\\\|"))` | \(.series) |") | join("\n"))' "$r/monitoring.json"
  fi
  if [[ -f $r/onboarding.json || -f $r/runbook.json ]]; then
    echo
    echo "## Onboarding and runbook timings"
    echo
    echo "| Step | Time |"
    echo "|---|---|"
    [[ -f $r/onboarding.json ]] && jq -r '"| initial onboarding of \(.namespaces) namespaces (\(.objects_per_namespace) objects each) | \(.initial_onboarding_ms) ms |"' "$r/onboarding.json"
    [[ -f $r/runbook.json ]] && jq -r '"| onboard a new team (team-c) | \(.onboard_new_tenant_ms) ms |\n| drift repair: deleted NetworkPolicy recreated | \(.drift_repair_ms) ms |\n| raise quota small -> medium (pods \(.quota_before.pods) -> \(.quota_after.pods)) | \(.quota_raise_ms) ms |\n| offboard team-c | \(.offboard_ms) ms |\n\ndefault-deny NetworkPolicy missing at any point during the tier change: \(.default_deny_gap_during_raise)"' "$r/runbook.json"
  fi
} >"$r/summary.md"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  cat "$r/summary.md" >>"$GITHUB_STEP_SUMMARY"
fi
cat "$r/summary.md"
