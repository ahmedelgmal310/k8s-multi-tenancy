#!/usr/bin/env bash
# Runs the tenancy conformance matrix (conformance/matrix.tsv). Every row is
# one ordinary kubectl or curl call made as a test identity; the observed
# result (allowed, or which layer denied it) is compared with the expected
# one. Any mismatch fails the job. Writes e2e-results/conformance.{json,md}.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=e2e/lib.sh
source e2e/lib.sh

server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# classify <exit code> <output>: name the layer that produced the result.
classify() {
  local rc=$1 out=$2
  if [[ $rc -eq 0 ]]; then
    echo allowed
  elif grep -q 'exceeded quota' <<<"$out"; then
    echo denied:quota
  elif grep -qE 'maximum (cpu|memory) usage per (Container|Pod)' <<<"$out"; then
    echo denied:limitrange
  elif grep -q 'violates PodSecurity' <<<"$out"; then
    echo denied:pss
  elif grep -q 'denied the request' <<<"$out"; then
    echo denied:policy
  elif grep -qiE '\(Forbidden\)|is forbidden|cannot (get|list|create|update|patch|delete)' <<<"$out"; then
    echo denied:rbac
  else
    echo error
  fi
}

# run_kubectl <identity> <args>: prints "<rc>\n<output>"
run_kubectl() {
  local who=$1 rc out
  local -a args
  read -r -a args <<<"$2"
  set +e
  out=$(as "$who" "${args[@]}" 2>&1 </dev/null)
  rc=$?
  set -e
  printf '%s\n%s' "$rc" "$out"
}

# run_api <identity> "<VERB> <path>": curl straight to the API server with
# the identity's client certificate. 2xx is allowed, 403 is an RBAC denial.
run_api() {
  local who=$1 verb path code
  read -r verb path <<<"$2"
  code=$(curl -sS -o "${RESULTS_DIR}/last-body.txt" -w '%{http_code}' -X "$verb" \
    --cacert "${ID_DIR}/ca.crt" --cert "${ID_DIR}/${who}.crt" --key "${ID_DIR}/${who}.key" \
    "${server}${path}" 2>&1) || true
  case $code in
    2??) printf '0\nHTTP %s' "$code" ;;
    403) printf '1\nHTTP 403 (Forbidden) %s' "$(jq -r '.message // empty' "${RESULTS_DIR}/last-body.txt" 2>/dev/null)" ;;
    *) printf '1\nHTTP %s %s' "$code" "$(head -c 200 "${RESULTS_DIR}/last-body.txt" 2>/dev/null)" ;;
  esac
}

# run_http <identity> "<ns>/<deployment> <url>": curl inside a tenant pod.
# Connection timeouts or refusals are what a NetworkPolicy drop looks like;
# DNS failures and HTTP errors are reported as errors, not as denials.
run_http() {
  local who=$1 src url ns deploy rc out
  read -r src url <<<"$2"
  ns=${src%%/*} deploy=${src##*/}
  set +e
  out=$(as "$who" exec -n "$ns" "deploy/${deploy}" -- \
    curl -sS -o /dev/null -m 3 -w '%{http_code}' "$url" 2>&1 </dev/null)
  rc=$?
  set -e
  out=$(grep -v '^command terminated with exit code' <<<"$out" || true)
  if [[ $rc -eq 0 && $out == *200 ]]; then
    printf '0\nHTTP 200'
  elif [[ $rc -eq 28 || $rc -eq 7 ]]; then
    printf '%s\nnetpol: connection failed (curl exit %s)' "$rc" "$rc"
  else
    printf '%s\n%s' "$rc" "$out"
  fi
}

results=()
failures=0
total=0
while IFS=$'\t' read -r id who method target expect check desc; do
  [[ -z $id || $id == \#* ]] && continue
  total=$((total + 1))
  case $method in
    kubectl) raw=$(run_kubectl "$who" "$target") ;;
    api) raw=$(run_api "$who" "$target") ;;
    http) raw=$(run_http "$who" "$target") ;;
    *) die "${id}: unknown method ${method}" ;;
  esac
  rc=$(head -n1 <<<"$raw")
  out=$(tail -n +2 <<<"$raw")
  if [[ $method == http && $out == netpol:* ]]; then
    observed=denied:netpol
  else
    observed=$(classify "$rc" "$out")
  fi

  detail=$(tr '\n' ' ' <<<"$out" | sed -E 's/^Error from server( \([A-Za-z]+\))?: //' | cut -c1-220)
  verdict=PASS
  [[ $observed == "$expect" ]] || verdict=FAIL

  # Allowed rows can also assert what the cluster did with the object.
  if [[ $verdict == PASS && $check != "-" ]]; then
    IFS='|' read -r cns cobj cpath cwant <<<"$check"
    got=""
    for _ in $(seq 1 15); do
      got=$(kubectl get -n "$cns" "$cobj" -o "jsonpath=${cpath}" 2>/dev/null || true)
      [[ $got == "$cwant" ]] && break
      sleep 1
    done
    detail="${detail} | check ${cpath} = ${got}"
    [[ $got == "$cwant" ]] || {
      verdict=FAIL
      detail="${detail} (expected ${cwant})"
    }
  fi
  [[ $verdict == FAIL ]] && failures=$((failures + 1))
  log "${verdict} ${id} [${who}]: expected ${expect}, observed ${observed}"
  [[ $verdict == FAIL ]] && log "  ${detail}"

  results+=("$(jq -cn --arg id "$id" --arg who "$who" --arg method "$method" --arg target "$target" \
    --arg expect "$expect" --arg observed "$observed" --arg verdict "$verdict" --arg desc "$desc" \
    --arg detail "$detail" \
    '{id:$id, identity:$who, method:$method, target:$target, expected:$expect, observed:$observed,
      verdict:$verdict, description:$desc, detail:$detail}')")
done <conformance/matrix.tsv

printf '%s\n' "${results[@]}" | jq -s --argjson failures "$failures" --argjson total "$total" \
  '{total:$total, failures:$failures, cases:.}' >"${RESULTS_DIR}/conformance.json"

{
  echo "| Identity | Action | Expected | Observed | Result |"
  echo "|---|---|---|---|---|"
  jq -r '.cases[] | "| `\(.identity)` | \(.description) | \(.expected) | \(.observed) | \(.verdict) |"' \
    "${RESULTS_DIR}/conformance.json"
} >"${RESULTS_DIR}/conformance.md"

jq -r '[.cases[] | .expected] | group_by(.) | map("\(.[0]): \(length)") | join(", ")' \
  "${RESULTS_DIR}/conformance.json" | while read -r line; do log "expected outcomes: ${line}"; done

log "conformance: $((total - failures))/${total} cases as expected"

# Remove what the allowed rows created, so later steps start from a known state.
for ns in "${TENANT_NAMESPACES[@]}"; do
  kubectl get deploy,pod,svc,configmap,secret,rolebinding -n "$ns" -o name 2>/dev/null |
    grep '/conf-' | xargs -r kubectl delete -n "$ns" --wait=true --ignore-not-found >/dev/null
done

[[ $failures -eq 0 ]] || die "${failures} conformance case(s) did not match the expected result"
