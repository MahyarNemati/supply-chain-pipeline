#!/usr/bin/env bash
# Exercises provenance.sh with a synthetic GitHub Actions environment and
# asserts on the predicate shape.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/.github/actions/sign-attest/provenance.sh"
failures=0

check() {
  local desc="$1" filter="$2" json="$3"
  if jq -e "$filter" >/dev/null <<<"$json"; then
    echo "ok   $desc"
  else
    echo "FAIL $desc"
    failures=$((failures + 1))
  fi
}

base_env=(
  GITHUB_SERVER_URL=https://github.com
  GITHUB_REPOSITORY=acme/app
  GITHUB_REPOSITORY_ID=1
  GITHUB_REPOSITORY_OWNER_ID=2
  GITHUB_SHA=0123456789abcdef0123456789abcdef01234567
  GITHUB_REF=refs/heads/main
  GITHUB_EVENT_NAME=push
  GITHUB_RUN_ID=42
  GITHUB_RUN_ATTEMPT=1
  GITHUB_WORKFLOW_REF=acme/app/.github/workflows/release.yml@refs/heads/main
  RUNNER_ENVIRONMENT=github-hosted
  PROV_BUILDER_ID=https://github.com/MahyarNemati/supply-chain-pipeline/.github/workflows/supply-chain.yml@refs/heads/main
  PROV_STARTED_ON=2026-01-01T00:00:00Z
  PROV_FINISHED_ON=2026-01-01T00:05:00Z
  PROV_CONTEXT=example
  PROV_DOCKERFILE=example/Dockerfile
  "PROV_PLATFORMS=linux/amd64, linux/arm64"
  $'PROV_BUILD_ARGS=VERSION=1.0.0\nCOMMIT=abc'
)

out="$(env -i PATH="$PATH" "${base_env[@]}" "$script")"

check "builder id is the reusable workflow" \
  '.runDetails.builder.id | endswith("supply-chain.yml@refs/heads/main")' "$out"
check "source commit is recorded" \
  '.buildDefinition.resolvedDependencies[0].digest.gitCommit == "0123456789abcdef0123456789abcdef01234567"' "$out"
check "platforms are split and trimmed" \
  '.buildDefinition.externalParameters.platforms == ["linux/amd64","linux/arm64"]' "$out"
check "build args are one entry per line" \
  '.buildDefinition.externalParameters.buildArgs == ["VERSION=1.0.0","COMMIT=abc"]' "$out"
check "invocation id points at the run attempt" \
  '.runDetails.metadata.invocationId == "https://github.com/acme/app/actions/runs/42/attempts/1"' "$out"
check "timestamps are passed through" \
  '.runDetails.metadata.startedOn == "2026-01-01T00:00:00Z" and .runDetails.metadata.finishedOn == "2026-01-01T00:05:00Z"' "$out"

if env -i PATH="$PATH" GITHUB_REPOSITORY=acme/app "$script" >/dev/null 2>&1; then
  echo "FAIL missing environment is rejected"
  failures=$((failures + 1))
else
  rc=$?
  if [[ $rc -eq 64 ]]; then
    echo "ok   missing environment is rejected"
  else
    echo "FAIL missing environment exits 64, got $rc"
    failures=$((failures + 1))
  fi
fi

if ((failures)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
