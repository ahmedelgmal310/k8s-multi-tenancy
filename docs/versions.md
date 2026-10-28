# Pinned versions

Every tool, chart, image and action is pinned. Images use `tag@sha256:digest`,
actions use a full commit SHA with the version in a comment, and downloaded
binaries are checked against a SHA-256. Policy: a version is adopted only after
it has been public for **at least two weeks** (Dependabot runs with a 14-day
cooldown), unless a security fix forces an earlier upgrade. Versions below
were checked on 2026-10-28.

## Policy engine

| Component | Version | Released | Pin |
|---|---|---|---|
| Kyverno (kyverno/kyverno chart) | 3.9.2 (Kyverno v1.19.2) | 2026-10-20 | chart version |
| Kyverno CLI (policy tests) | v1.19.2 | 2026-10-20 | `ghcr.io/kyverno/kyverno-cli@sha256:322ec5044d600930cb3af0e56dc33154a2d1d1fba58f4cadad3f47be7e78b11c` |

> **Security exception: Kyverno 1.19.2 is 8 days old.** It is the fix release
> for 24 GitHub Security Advisories (9 critical, 14 high), including
> GHSA-q62c-r9v2-cf64 / GHSA-hg5v-hwm3-956r / GHSA-493q-9xvg-9xf3 in *generate
> authorization, clone namespace confinement and internal-label protection*,
> which is exactly the code path tenant onboarding depends on, and
> GHSA-m8p2-qqmx-j53x (CEL evaluation cost limits) for the CEL policies here.
> The previous release that satisfies the two-week rule, 1.19.1 (2026-09-10),
> is affected. Running a multi-tenancy control plane on a version with known
> critical advisories in its generate path is worse than taking a young patch
> release, so this repository takes 1.19.2 now. The Kyverno images inside the
> chart are pinned by the chart version (tag `v1.19.2`), not by digest.

## Cluster and platform (e2e)

| Component | Version | Released | Pin |
|---|---|---|---|
| kind | v0.33.0 | 2026-08-26 | `helm/kind-action` input |
| Kubernetes (kindest/node) | v1.36.4 | 2026-08-20 | `sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed` |
| kubectl | v1.36.4 | 2026-08-20 | `helm/kind-action` input |
| Helm | v4.3.0 | 2026-09-09 | `azure/setup-helm` input |
| prometheus-community/prometheus chart | 29.35.0 | 2026-09-27 | chart version |
| Prometheus server (and promtool) | v3.15.0 | 2026-09-25 | `quay.io/prometheus/prometheus@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e` |
| kube-state-metrics (chart subchart 8.6.0) | v2.20.0 | 2026-08-18 | `registry.k8s.io/kube-state-metrics/kube-state-metrics@sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b` |

Helm 4.3.1 (2026-10-15) is a non-security patch and still inside the window.

## Test workload images

| Image | Version | Pin | Why |
|---|---|---|---|
| registry.k8s.io/e2e-test-images/agnhost | 2.63.0 | `sha256:a62f40481e05709988fe44e5035b2e0f553cd52bf0ae4e83614928255b00e8c1` | HTTP echo (`netexec`); the version the Kubernetes v1.36.4 e2e suite uses |
| registry.k8s.io/e2e-test-images/busybox | 1.37.0-1 | `sha256:0ffbe172f8d245c83f285c6992b452c53d085661e03ddfd3b484332026e6c8bb` | CPU burner for the noisy neighbour; same source |
| docker.io/curlimages/curl | 8.22.0 (2026-09-02) | `sha256:43366cd60f226c7655181a0f7e85c468a41d182fdd2dc2c1c3b872a2b9d05d7a` | curl inside tenant pods (network rows, latency probe) |

## CI (`.github/workflows/ci.yml`)

| Tool | Version | Pin |
|---|---|---|
| actions/checkout | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| actions/upload-artifact | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| helm/kind-action | v1.15.1 | `1544676c07bb3570fcb70166beaa07c4528fd4aa` |
| azure/setup-helm | v5.0.1 | `9bc31f4ebc9c6b171d7bfbaa5d006ae7abdb4310` |
| kubeconform | v0.8.0 (2026-06-04) | SHA-256 `9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883` |
| datreeio/CRDs-catalog (Kyverno CRD schemas) | commit of 2026-10-08 | `63669a570e231d4f1f8396d229a1de512bcf0a34` |
| Gitleaks | v8.30.1 | `ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f` |
| actionlint | 1.7.12 | `mirror.gcr.io/rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667` |
| shellcheck | runner image | preinstalled on `ubuntu-latest` (version printed in the log) |

No Go or other application code is written in this repository, so there is no
Go toolchain, module list or coverage gate.
