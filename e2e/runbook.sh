#!/usr/bin/env bash
# Exercises the runbook on the live cluster and times each step:
#   1. onboard a new team (team-c) from one file
#   2. drift repair: a tenant NetworkPolicy deleted by an operator comes back
#   3. raise a quota: move team-b from the small to the medium tier
#   4. offboard team-c
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=e2e/lib.sh
source e2e/lib.sh

has_netpol() { kubectl get networkpolicy "$2" -n "$1" >/dev/null 2>&1; }
pods_hard() { kubectl get resourcequota tenant-quota -n "$1" -o jsonpath='{.spec.hard.pods}' 2>/dev/null; }

# 1. Onboard
log "onboarding team-c"
start=$(now_ms)
kubectl apply -f e2e/fixtures/team-c.yaml
wait_for 120 fully_onboarded team-c-apps || die "team-c: $(object_count team-c-apps)/${OBJECTS_PER_NAMESPACE} objects"
onboard_ms=$(($(now_ms) - start))
log "team-c onboarded: ${OBJECTS_PER_NAMESPACE} objects in ${onboard_ms} ms"

# 2. Drift repair (synchronize)
log "deleting team-c's default-deny NetworkPolicy as cluster-admin"
start=$(now_ms)
kubectl delete networkpolicy default-deny-all -n team-c-apps --wait=true
wait_for 120 has_netpol team-c-apps default-deny-all || die "default-deny-all was not recreated"
drift_ms=$(($(now_ms) - start))
log "default-deny-all recreated after ${drift_ms} ms"

# 3. Raise team-b's quota: the change is one label in tenants/team-b.yaml
log "raising team-b from small to medium"
before_hard=$(kubectl get resourcequota tenant-quota -n team-b-apps -o jsonpath='{.spec.hard}')
gap_seen=false
start=$(now_ms)
sed 's/tenancy.io\/tier: small/tenancy.io\/tier: medium/' tenants/team-b.yaml | kubectl apply -f -
ok=false
for _ in $(seq 1 240); do
  # Watch the isolation objects while the tenant objects are re-synced.
  has_netpol team-b-apps default-deny-all || gap_seen=true
  if [[ $(pods_hard team-b-apps) == 30 ]] && fully_onboarded team-b-apps; then
    ok=true
    break
  fi
  sleep 0.5
done
$ok || die "team-b quota did not move to the medium tier: $(kubectl get resourcequota -n team-b-apps -o yaml)"
raise_ms=$(($(now_ms) - start))
after_hard=$(kubectl get resourcequota tenant-quota -n team-b-apps -o jsonpath='{.spec.hard}')
log "team-b quota raised in ${raise_ms} ms: ${before_hard} -> ${after_hard} (default-deny gap observed: ${gap_seen})"
# The raised namespace must still be isolated.
as b-admin exec -n team-b-apps deploy/client -- curl -sS -o /dev/null -m 3 \
  http://echo.team-a-backend.svc.cluster.local:8080/hostname </dev/null 2>/dev/null &&
  die "team-b reached team-a after the tier change"

# 4. Offboard
log "offboarding team-c"
start=$(now_ms)
kubectl delete -f e2e/fixtures/team-c.yaml --wait=true --timeout=180s
offboard_ms=$(($(now_ms) - start))
left=$(kubectl get rolebindings,resourcequotas,networkpolicies -A -l tenancy.io/tenant=team-c -o name | wc -l)
log "team-c offboarded in ${offboard_ms} ms, ${left} objects left behind"
((left == 0)) || die "objects of team-c survived offboarding"

jq -n --argjson o "$onboard_ms" --argjson d "$drift_ms" --argjson r "$raise_ms" --argjson off "$offboard_ms" \
  --argjson b "$before_hard" --argjson a "$after_hard" --argjson gap "$gap_seen" \
  '{onboard_new_tenant_ms:$o, drift_repair_ms:$d, quota_raise_ms:$r, quota_before:$b, quota_after:$a,
    default_deny_gap_during_raise:$gap, offboard_ms:$off}' >"${RESULTS_DIR}/runbook.json"
