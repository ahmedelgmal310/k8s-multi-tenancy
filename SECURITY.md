# Security Policy

## Scope

This repository is a reference implementation of namespace-based
multi-tenancy on a shared Kubernetes cluster: tenant onboarding driven by
Kyverno, tenant RBAC, quotas, LimitRanges, NetworkPolicies, Pod Security
admission and admission guardrails. The security-relevant artifacts are the
policies in `platform/`, the tenant files in `tenants/` and the CI checks that
prove them.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/ahmedelgmal310/k8s-multi-tenancy/security/advisories/new).
Do not open a public issue. You can expect an acknowledgement within 72 hours.

An isolation gap counts as a vulnerability: for example an action the
conformance matrix (`conformance/matrix.tsv`) says must be denied, but that a
different verb, subresource, object kind or encoding gets through. Please
include the command so it can be added to the matrix as a regression case.

## Controls in this repository

- Every GitHub Action is pinned to a full commit SHA, container images by
  digest, downloaded binaries by SHA-256 (see `docs/versions.md`). Dependabot
  proposes updates with a 14-day cooldown.
- No credentials are committed. The test identities (EC private keys and
  client certificates with a 1-hour lifetime, signed through the
  CertificateSigningRequest API) are created on the runner per CI run, live
  outside the checkout, and are deleted at the end of the job. `.gitignore`
  blocks keys, certificates and kubeconfigs.
- CI gates: Gitleaks (full history), shellcheck, actionlint, kubeconform
  (Kubernetes and Kyverno schemas), Kyverno CLI policy tests, promtool rule
  tests, and the conformance matrix on a live kind cluster.
- The Kyverno webhooks fail closed: if Kyverno is down, tenant writes that the
  policies cover are rejected rather than admitted unchecked.
