#!/usr/bin/env bash
# Shared helpers for the e2e scripts. Source it; do not run it.
# shellcheck shell=bash

RESULTS_DIR="${RESULTS_DIR:-e2e-results}"
# Per-run test identities (private keys, client certificates, kubeconfigs).
# Kept outside the repository and discarded with the runner.
ID_DIR="${ID_DIR:-${RUNNER_TEMP:-/tmp}/tenancy-identities}"
# shellcheck disable=SC2034 # used by the scripts that source this file
TENANT_NAMESPACES=(team-a-frontend team-a-backend team-b-apps)
mkdir -p "$RESULTS_DIR"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

die() {
  log "FAIL: $*"
  exit 1
}

# as <identity> <kubectl args...>: run kubectl as a test identity.
# "platform" is the cluster-admin context the job was started with.
as() {
  local who=$1
  shift
  if [[ $who == platform ]]; then
    kubectl "$@"
  else
    kubectl --kubeconfig "${ID_DIR}/${who}.kubeconfig" "$@"
  fi
}

# now_ms: wall clock in milliseconds.
now_ms() { date +%s%3N; }

# wait_for <timeout-seconds> <command...>: retry a command once a second.
wait_for() {
  local timeout=$1 start=$SECONDS
  shift
  until "$@" >/dev/null 2>&1; do
    ((SECONDS - start >= timeout)) && return 1
    sleep 1
  done
}

# object_count <namespace>: number of objects tenant-onboarding created there.
object_count() {
  local n=0 kind
  for kind in rolebindings resourcequotas limitranges networkpolicies; do
    n=$((n + $(kubectl get "$kind" -n "$1" -l tenancy.io/managed-by=tenant-onboarding -o name 2>/dev/null | wc -l)))
  done
  echo "$n"
}

# The tenant-onboarding policy creates 9 objects per tenant namespace:
# 3 RoleBindings, 2 ResourceQuotas, 1 LimitRange, 3 NetworkPolicies.
OBJECTS_PER_NAMESPACE=9

fully_onboarded() { [[ $(object_count "$1") -eq $OBJECTS_PER_NAMESPACE ]]; }

# prom_query <promql>: first value of an instant query, or "NaN".
prom_query() {
  local q
  q=$(jq -rn --arg q "$1" '$q|@uri')
  kubectl get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query?query=${q}" |
    jq -r '.data.result[0].value[1] // "NaN"'
}

# prom_series <promql>: number of series an instant query returns.
prom_series() {
  local q
  q=$(jq -rn --arg q "$1" '$q|@uri')
  kubectl get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query?query=${q}" |
    jq -r '.data.result | length'
}

# prom_get <path>: raw JSON from the Prometheus HTTP API.
prom_get() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy$1"
}

# percentiles <file of "code seconds" lines>: JSON summary in milliseconds.
percentiles() {
  awk '{ if ($1 == "200") { ok++; print $2 * 1000 } else { fail++ } }
       END { printf "%d %d\n", ok, fail > "/dev/stderr" }' "$1" 2>"$1.counts" | sort -n >"$1.sorted"
  local ok fail
  read -r ok fail <"$1.counts"
  awk -v ok="$ok" -v fail="$fail" '
    { v[NR] = $1 }
    function pct(p,   i) { i = int(NR * p + 0.999999); if (i < 1) i = 1; if (i > NR) i = NR; return v[i] }
    END {
      if (NR == 0) { printf "{\"ok\":%d,\"failed\":%d}\n", ok, fail; exit }
      printf "{\"ok\":%d,\"failed\":%d,\"p50_ms\":%.2f,\"p95_ms\":%.2f,\"p99_ms\":%.2f,\"max_ms\":%.2f}\n",
        ok, fail, pct(0.50), pct(0.95), pct(0.99), v[NR]
    }' "$1.sorted"
}
