# supply-chain-pipeline

Reusable GitHub Actions workflow that builds a container image, inventories and scans it, signs it keylessly and attaches SBOM and SLSA provenance attestations, with a Kubernetes admission policy that only runs what the workflow signed.

[![ci](https://github.com/MahyarNemati/supply-chain-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/MahyarNemati/supply-chain-pipeline/actions/workflows/ci.yml)
[![example](https://github.com/MahyarNemati/supply-chain-pipeline/actions/workflows/example.yml/badge.svg)](https://github.com/MahyarNemati/supply-chain-pipeline/actions/workflows/example.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![SLSA](https://img.shields.io/badge/SLSA-Build%20L2%2B-informational)
![Go](https://img.shields.io/badge/go-1.24-00ADD8?logo=go&logoColor=white)

## Features

- `workflow_call` workflow: Buildx multi-platform build and push to GHCR by digest.
- Syft SBOMs in SPDX JSON and CycloneDX JSON, generated from the pushed digest.
- Grype severity gate that scans the SBOM itself, so the gate and the attestation describe the same inventory. Results go to GitHub code scanning as SARIF.
- Keyless cosign signing through GitHub OIDC and Fulcio, logged in Rekor.
- cosign attestations for SPDX, CycloneDX and SLSA v1 provenance, plus GitHub artifact attestations (`attest-build-provenance`, `attest` with an SBOM) pushed to the registry.
- Least privilege per job: only the `sign` job holds `id-token: write`, and it never executes the caller's build.
- Composite action `sign-attest` usable on its own for images built elsewhere.
- Every third-party action pinned to a full commit SHA with a version comment; CI rejects unpinned references.
- Example Go service, `verify.sh` built on `cosign verify` and `cosign verify-attestation`, and a Kyverno `ClusterPolicy` that admits only images signed by this workflow and rewrites them to digests.
- [Threat model](docs/threat-model.md) mapped to SLSA Build levels.

## Architecture

```mermaid
flowchart TD
  subgraph caller["Caller repository"]
    c[example.yml<br/>uses: supply-chain.yml]
  end
  subgraph reusable["supply-chain.yml"]
    b["build<br/>buildx, push by digest<br/>packages: write"]
    s["scan<br/>syft SPDX + CycloneDX<br/>grype gate, SARIF"]
    g["sign<br/>id-token: write<br/>sign-attest composite"]
    b -->|image@digest| s
    s -->|SBOM artifact| g
    b -->|digest| g
  end
  c --> b
  b --> ghcr[(GHCR)]
  g -->|signature, attestations| ghcr
  g -->|certificate| fulcio[(Fulcio)]
  g -->|log entries| rekor[(Rekor)]
  ghcr --> ky{Kyverno<br/>verifyImages}
  ky -->|signed, attested| pod[Pod pinned to digest]
  ky -.->|otherwise| deny[Rejected]
```

On pull requests (`push: false`) the build job loads a single-platform image locally and runs the Grype gate against it; nothing is pushed or signed.

The `sign` job decodes its own OIDC token to read `job_workflow_ref` and `job_workflow_sha`, then checks out this repository at that SHA to run the composite action. The composite action therefore always matches the workflow version the caller pinned, which is also the identity Fulcio writes into the signing certificate.

## Quickstart

Call the workflow from any repository:

```yaml
# .github/workflows/release.yml
name: release
on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:

permissions: {}

jobs:
  image:
    permissions:
      contents: read
      packages: write
      id-token: write
      attestations: write
      security-events: write
    uses: MahyarNemati/supply-chain-pipeline/.github/workflows/supply-chain.yml@<commit-sha> # v1.0.0
    with:
      context: .
      dockerfile: Dockerfile
      push: ${{ github.event_name != 'pull_request' }}
      severity-cutoff: high
```

Verify what it published:

```sh
example/verify.sh ghcr.io/<owner>/<repo>@sha256:<digest>
# or, with the source repository also checked against the provenance:
SOURCE_REPOSITORY=<owner>/<repo> VERIFY_GH_ATTESTATIONS=1 example/verify.sh ghcr.io/<owner>/<repo>@sha256:<digest>
```

Enforce it in a cluster that runs Kyverno 1.13 or newer:

```sh
kubectl apply -f example/policy/kyverno-verify-images.yaml
```

## Configuration

Workflow inputs:

| Input | Default | Description |
|---|---|---|
| `image-name` | `ghcr.io/<owner>/<repo>` | Image repository, lower-cased, no tag |
| `context` | `.` | Build context |
| `dockerfile` | `Dockerfile` | Dockerfile path |
| `platforms` | `linux/amd64,linux/arm64` | Target platforms when pushing |
| `build-args` | empty | Newline separated; recorded in provenance |
| `push` | `true` | `false` builds and scans only |
| `severity-cutoff` | `high` | Lowest Grype severity that fails the run |
| `only-fixed` | `true` | Gate only on vulnerabilities with a published fix |
| `runs-on` | `ubuntu-24.04` | Runner label; the policy requires GitHub-hosted |

Outputs: `image`, `digest`.

Required caller permissions: `contents: read`, `packages: write`, `id-token: write`, `attestations: write`, `security-events: write`.

`verify.sh` environment:

| Variable | Default | Description |
|---|---|---|
| `CERT_IDENTITY_REGEXP` | this workflow on `main` or `vX.Y.Z` | Accepted signer identity |
| `CERT_OIDC_ISSUER` | `https://token.actions.githubusercontent.com` | Accepted OIDC issuer |
| `SOURCE_REPOSITORY` | unset | Also require the certificate and provenance to name this source repo |
| `VERIFY_GH_ATTESTATIONS` | `0` | `1` additionally runs `gh attestation verify` |

Example service environment:

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | Listen port |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `MAX_BODY_BYTES` | `1048576` | Request body limit, up to 64 MiB |
| `SHUTDOWN_TIMEOUT` | `10s` | Graceful shutdown deadline |

## Usage

### Attestations attached to every image

| Type | Producer | Predicate type | Verify with |
|---|---|---|---|
| Signature | cosign | n/a | `cosign verify` |
| SPDX SBOM | cosign | `https://spdx.dev/Document` | `cosign verify-attestation --type spdxjson` |
| CycloneDX SBOM | cosign | `https://cyclonedx.org/bom` | `cosign verify-attestation --type cyclonedx` |
| SLSA provenance | cosign + `provenance.sh` | `https://slsa.dev/provenance/v1` | `cosign verify-attestation --type slsaprovenance1` |
| Build provenance | `actions/attest-build-provenance` | `https://slsa.dev/provenance/v1` | `gh attestation verify` |
| SBOM | `actions/attest` | `https://spdx.dev/Document` | `gh attestation verify --predicate-type` |

### Composite action on its own

```yaml
- uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2
- uses: MahyarNemati/supply-chain-pipeline/.github/actions/sign-attest@<commit-sha>
  with:
    image: ghcr.io/acme/app
    digest: ${{ steps.build.outputs.digest }}
    spdx-path: sbom.spdx.json
    cyclonedx-path: sbom.cdx.json
    builder-id: https://github.com/${{ github.workflow_ref }}
    build-started-on: ${{ steps.start.outputs.time }}
    context: .
    dockerfile: Dockerfile
    platforms: linux/amd64
```

### Example service API

| Method | Path | Description |
|---|---|---|
| `GET` | `/healthz` | Liveness |
| `GET` | `/version` | Version, commit and build date stamped at link time |
| `POST` | `/v1/digest?alg=sha256\|sha512` | Digest of the request body |

## Testing

```sh
make test     # Go tests with -race, provenance and verify script tests
make lint     # actionlint, shellcheck, yamllint, go vet, staticcheck, golangci-lint
make policy   # kubeconform against the Kyverno CRD schema
```

What was validated locally before each commit (Linux x86_64 sandbox, Go 1.24.7, no Docker daemon, no GitHub credentials):

| Check | Result |
|---|---|
| `go test -race ./...` in `example/` | pass |
| `go vet`, `staticcheck` v0.6.1, `golangci-lint` v2.8.0 | clean |
| `actionlint` v1.7.7 on all workflows | clean |
| `shellcheck` on all scripts | clean |
| `yamllint --strict` | clean |
| `kubeconform -strict` on the Kyverno policy with the datree CRD catalog | valid |
| `tests/provenance_test.sh`: predicate shape from a synthetic Actions environment | 7/7 pass |
| `tests/verify_test.sh`: `verify.sh` against a stubbed cosign, accept and reject paths | 7/7 pass |
| Action inputs | each pinned action's `action.yml` at its SHA was read and the inputs used here cross-checked |

Not validated here: an end-to-end run on GitHub (needs the repository on GitHub with Actions and GHCR enabled), a real cosign signature against Fulcio and Rekor, the Docker image build (no Docker daemon in the sandbox), and Kyverno admission in a live cluster. The first push to `main` exercises the full path through `example.yml`.

## Design decisions and trade-offs

- **Push before the gate.** Multi-platform images cannot be loaded into the local daemon, so the image is pushed by digest first and scanned from the registry. An image that fails the gate stays unsigned and the policy rejects it. The cost is unsigned images in GHCR, cleaned up by a retention policy.
- **Scan the SBOM.** Grype reads the attested SPDX document instead of pulling the image again. The vulnerability decision and the published inventory cannot drift apart.
- **Two provenance formats.** The cosign attestation is verifiable with plain `cosign` and Kyverno anywhere. GitHub's attestation is produced by the platform, which is the stronger claim, but verification needs `gh` or the GitHub API. Shipping both keeps offline and air-gapped verifiers working.
- **No slsa-github-generator.** It reaches Build L3 but must be referenced by tag. SHA pinning was the higher priority; the gap is spelled out in the threat model.
- **Buildx attestations off.** `provenance: false` and `sbom: false` keep one signer and one verification path for every attestation instead of a mix of unsigned BuildKit attestations and signed ones.
- **Separate jobs.** The build job runs untrusted caller code and gets no OIDC permission. Splitting jobs costs some runner time and an artifact hand-off.
- **Distroless static, nonroot.** The example image has no shell or package manager, which keeps the SBOM short and the scan meaningful.

## Roadmap

- End-to-end run on GitHub and published example image with a link to its Rekor entries.
- sigstore `policy-controller` `ClusterImagePolicy` as an alternative to Kyverno.
- VEX document support in the Grype gate for accepted findings.
- Scheduled rescan of stored SBOMs against the latest Grype DB.
- Optional Build L3 path through `slsa-github-generator` for consumers who accept tag pinning for that one workflow.
- Scoped Buildx cache keys so pull request builds cannot seed protected-branch caches.

## Project structure

```
.github/
  actions/sign-attest/     composite action and SLSA provenance generator
  workflows/
    supply-chain.yml       reusable workflow (workflow_call)
    example.yml            caller: tests and publishes the example service
    ci.yml                 lint, tests, policy schema
docs/threat-model.md       threats, controls, SLSA mapping
example/
  cmd/server/              service entrypoint
  internal/config/         env config with validation
  internal/httpapi/        HTTP handlers and request logging
  policy/                  Kyverno ClusterPolicy
  verify.sh                cosign verification script
  Dockerfile
tests/                     shell tests for provenance.sh and verify.sh
```

## License

[MIT](LICENSE)
