#!/usr/bin/env bash
# Creates one test identity per tenant role: a private key created on the
# runner, a client certificate signed by the cluster CA through the
# CertificateSigningRequest API (signer kubernetes.io/kube-apiserver-client,
# 1 hour lifetime), and a kubeconfig. The certificate subject carries the
# identity: CN is the user name, O is the group the tenant RoleBindings use.
# Nothing is written inside the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=e2e/lib.sh
source e2e/lib.sh

# identity  user   group
IDENTITIES=(
  "a-admin alice team-a:admins"
  "a-dev amir team-a:developers"
  "a-viewer ava team-a:viewers"
  "b-admin bob team-b:admins"
  "b-dev bea team-b:developers"
  "b-viewer ben team-b:viewers"
)

umask 077
mkdir -p "$ID_DIR"
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' |
  base64 -d >"${ID_DIR}/ca.crt"

whoami_rows=()
for row in "${IDENTITIES[@]}"; do
  read -r id user group <<<"$row"
  key="${ID_DIR}/${id}.key" crt="${ID_DIR}/${id}.crt" cfg="${ID_DIR}/${id}.kubeconfig"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key" 2>/dev/null
  csr=$(openssl req -new -key "$key" -subj "/CN=${user}/O=${group}" | base64 -w0)
  kubectl apply -f - >/dev/null <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: tenancy-e2e-${id}
spec:
  request: ${csr}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 3600
  usages: [client auth]
EOF
  kubectl certificate approve "tenancy-e2e-${id}" >/dev/null
  cert=""
  for _ in $(seq 1 60); do
    cert=$(kubectl get csr "tenancy-e2e-${id}" -o jsonpath='{.status.certificate}')
    [[ -n $cert ]] && break
    sleep 1
  done
  [[ -n $cert ]] || die "CSR for ${id} was not signed"
  base64 -d <<<"$cert" >"$crt"

  kubectl config --kubeconfig "$cfg" set-cluster kind --server "$server" \
    --certificate-authority "${ID_DIR}/ca.crt" --embed-certs >/dev/null
  kubectl config --kubeconfig "$cfg" set-credentials "$user" \
    --client-certificate "$crt" --client-key "$key" --embed-certs >/dev/null
  kubectl config --kubeconfig "$cfg" set-context default --cluster kind --user "$user" >/dev/null
  kubectl config --kubeconfig "$cfg" use-context default >/dev/null

  # The API server must see exactly the user and group from the certificate.
  info=$(kubectl --kubeconfig "$cfg" auth whoami -o json)
  seen_user=$(jq -r '.status.userInfo.username' <<<"$info")
  jq -e --arg g "$group" '.status.userInfo.groups | index($g)' <<<"$info" >/dev/null ||
    die "${id}: API server does not see group ${group}: ${info}"
  [[ $seen_user == "$user" ]] || die "${id}: API server sees user ${seen_user}, expected ${user}"
  not_after=$(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)
  log "${id}: user=${seen_user} groups=$(jq -c '.status.userInfo.groups' <<<"$info") cert valid until ${not_after}"
  whoami_rows+=("$(jq -c --arg id "$id" --arg na "$not_after" \
    '{identity:$id, user:.status.userInfo.username, groups:.status.userInfo.groups, cert_not_after:$na}' <<<"$info")")
done

printf '%s\n' "${whoami_rows[@]}" | jq -s . >"${RESULTS_DIR}/identities.json"
