#!/usr/bin/env bash
# Fair-share demo. team-a's frontend calls its backend in a loop (latency
# baseline); then team-b's developer deploys 40 CPU burners. The small-tier
# quota caps how many exist and their CPU limits cap what they can burn; the
# latency loop runs again while they burn. Fails if any team-a request fails,
# a team-a pod restarts or goes unready, or team-b gets more pods than its
# quota allows. Also checks the quota alert and the dashboard queries while
# team-b is at its limit (e2e/monitoring.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=e2e/lib.sh
source e2e/lib.sh

REQUESTS="${REQUESTS:-300}"
URL="http://echo.team-a-backend.svc.cluster.local:8080/hostname"

# probe <label>: REQUESTS sequential requests frontend -> backend, measured by curl.
probe() {
  local file="${RESULTS_DIR}/latency-$1.txt"
  # shellcheck disable=SC2016 # expanded by the pod's shell
  kubectl exec -n team-a-frontend deploy/client -- sh -c '
    i=0
    while [ "$i" -lt "$1" ]; do
      curl -s -o /dev/null -m 2 -w "%{http_code} %{time_total}\n" "$2" || true
      i=$((i + 1))
    done' _ "$REQUESTS" "$URL" >"$file" </dev/null
  percentiles "$file"
}

# team_a_health: "<ready pods>/<pods> <total restarts>"
team_a_health() {
  kubectl get pods -n team-a-frontend -o json >"${RESULTS_DIR}/.a1.json"
  kubectl get pods -n team-a-backend -o json >"${RESULTS_DIR}/.a2.json"
  jq -s -r '[.[].items[]] |
    "\([.[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length)/\(length) \([.[].status.containerStatuses[]?.restartCount] | add // 0)"' \
    "${RESULTS_DIR}/.a1.json" "${RESULTS_DIR}/.a2.json"
}

quota_field() { kubectl get resourcequota tenant-quota -n team-b-apps -o jsonpath="{.status.$1.$2}"; }

log "baseline: ${REQUESTS} requests team-a-frontend -> team-a-backend"
before=$(probe before)
health_before=$(team_a_health)
log "baseline latency: ${before}; team-a pods ready/total, restarts: ${health_before}"
pods_before=$(quota_field used pods)

log "team-b developer deploys 40 CPU burners"
as b-dev apply -f e2e/fixtures/noisy-neighbour.yaml
hard_pods=$(quota_field hard pods)
for _ in $(seq 1 120); do
  [[ $(quota_field used pods) == "$hard_pods" ]] && break
  sleep 1
done
kubectl -n team-b-apps wait pods -l app.kubernetes.io/name=noisy --for=condition=Ready --timeout=120s >/dev/null
admitted=$(kubectl get pods -n team-b-apps -l app.kubernetes.io/name=noisy --no-headers | wc -l)
rejections=$(kubectl get events -n team-b-apps --field-selector reason=FailedCreate -o json |
  jq '[.items[] | select(.message | test("exceeded quota"))] | map(.count // 1) | add // 0')
example=$(kubectl get events -n team-b-apps --field-selector reason=FailedCreate -o json |
  jq -r '[.items[] | select(.message | test("exceeded quota"))][0].message // ""' | cut -c1-240)
log "noisy: 40 requested, ${admitted} admitted, ${rejections} pod creations rejected by quota"
log "  e.g. ${example}"
log "team-b quota: used $(kubectl get resourcequota tenant-quota -n team-b-apps -o jsonpath='{.status.used}')"

log "letting the burners run for 45s (CPU usage rate window)"
sleep 45
during=$(probe during)
health_during=$(team_a_health)
log "latency while team-b burns CPU: ${during}; team-a pods ready/total, restarts: ${health_during}"

cpu_b=$(prom_query 'tenant:cpu_usage:cores{tenant="team-b"}')
cpu_a=$(prom_query 'tenant:cpu_usage:cores{tenant="team-a"}')
pods_ratio=$(prom_query 'tenant_namespace_resource:quota_usage:ratio{tenant="team-b", resource="pods"}')
alert_state=$(prom_get /api/v1/alerts | jq -r '[.data.alerts[] | select(.labels.alertname == "TenantQuotaNearLimit" and .labels.tenant == "team-b")][0].state // "none"')
log "Prometheus: team-b CPU ${cpu_b} cores, team-a CPU ${cpu_a} cores, team-b pods quota ratio ${pods_ratio}, TenantQuotaNearLimit(team-b): ${alert_state}"

RESULTS_DIR="$RESULTS_DIR" e2e/monitoring.sh

jq -n --argjson before "$before" --argjson during "$during" \
  --arg hb "$health_before" --arg hd "$health_during" \
  --argjson requested 40 --argjson admitted "$admitted" --argjson rejections "$rejections" \
  --arg example "$example" --argjson pods_before "$pods_before" --argjson hard_pods "$hard_pods" \
  --arg cpu_b "$cpu_b" --arg cpu_a "$cpu_a" --arg ratio "$pods_ratio" --arg alert "$alert_state" \
  --arg quota "$(kubectl get resourcequota tenant-quota -n team-b-apps -o json | jq -c '{hard:.status.hard, used:.status.used}')" \
  --argjson n "$REQUESTS" \
  '{requests_per_probe:$n, team_a_latency:{before:$before, during:$during},
    team_a_health:{before:$hb, during:$hd},
    noisy:{requested_replicas:$requested, admitted_replicas:$admitted, quota_rejections:$rejections,
           example_rejection:$example, team_b_pods_before:$pods_before, team_b_pod_quota:$hard_pods,
           team_b_quota:($quota|fromjson)},
    prometheus:{team_b_cpu_cores:$cpu_b, team_a_cpu_cores:$cpu_a, team_b_pods_quota_ratio:$ratio,
                quota_near_limit_alert_team_b:$alert}}' >"${RESULTS_DIR}/fairshare.json"

log "removing the noisy deployment (team-b developer)"
as b-dev delete -f e2e/fixtures/noisy-neighbour.yaml --wait=true
kubectl -n team-b-apps wait pods -l app.kubernetes.io/name=noisy --for=delete --timeout=120s >/dev/null 2>&1 || true

# Verdicts
failed_during=$(jq -r '.failed' <<<"$during")
[[ $failed_during -eq 0 ]] || die "${failed_during} team-a requests failed while team-b was noisy"
[[ ${health_during%% *} == "${health_before%% *}" ]] || die "team-a readiness changed: ${health_before} -> ${health_during}"
[[ ${health_during##* } == "${health_before##* }" ]] || die "team-a pods restarted while team-b was noisy"
((admitted + pods_before <= hard_pods)) || die "team-b has more pods than its quota allows"
((admitted < 40)) || die "quota did not limit the noisy deployment"
((rejections > 0)) || die "no quota rejections recorded"
[[ $pods_ratio == 1 ]] || die "Prometheus does not show team-b at 100% of its pod quota (got ${pods_ratio})"
[[ $alert_state == pending || $alert_state == firing ]] || die "TenantQuotaNearLimit is not active for team-b (${alert_state})"
log "fair share held: team-b capped at ${admitted}/40 replicas, team-a p95 $(jq -r '.p95_ms' <<<"$before") ms -> $(jq -r '.p95_ms' <<<"$during") ms, 0 failed requests"
