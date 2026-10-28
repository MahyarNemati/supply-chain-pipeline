#!/usr/bin/env bash
# Verifies the signature and attestations of an image published by the
# supply-chain reusable workflow.
#
#   example/verify.sh ghcr.io/owner/digest-service@sha256:...
#
# Environment:
#   CERT_IDENTITY_REGEXP  allowed signer identity (default: this repo's reusable workflow on main or a tag)
#   CERT_OIDC_ISSUER      expected OIDC issuer (default: GitHub Actions)
#   SOURCE_REPOSITORY     repository the image must have been built from (optional)
#   VERIFY_GH_ATTESTATIONS=1 also run `gh attestation verify`
set -euo pipefail

readonly DEFAULT_IDENTITY='^https://github\.com/MahyarNemati/supply-chain-pipeline/\.github/workflows/supply-chain\.yml@refs/(heads/main|tags/v[0-9]+\.[0-9]+\.[0-9]+)$'
identity_re="${CERT_IDENTITY_REGEXP:-$DEFAULT_IDENTITY}"
issuer="${CERT_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}

log() { printf '%s %s\n' "==>" "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || usage
ref="$1"
[[ "$ref" =~ @sha256:[a-f0-9]{64}$ ]] || die "reference must be pinned by digest: $ref"

for bin in cosign jq; do
  command -v "$bin" >/dev/null || die "$bin is required"
done

identity_flags=(--certificate-identity-regexp "$identity_re" --certificate-oidc-issuer "$issuer")
if [[ -n "${SOURCE_REPOSITORY:-}" ]]; then
  identity_flags+=(--certificate-github-workflow-repository "$SOURCE_REPOSITORY")
fi

log "verifying signature"
cosign verify "${identity_flags[@]}" "$ref" >/dev/null

declare -A predicate_types=(
  [spdxjson]="https://spdx.dev/Document"
  [cyclonedx]="https://cyclonedx.org/bom"
  [slsaprovenance1]="https://slsa.dev/provenance/v1"
)

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

for type in spdxjson cyclonedx slsaprovenance1; do
  log "verifying $type attestation"
  cosign verify-attestation "${identity_flags[@]}" --type "$type" "$ref" >"$workdir/$type.jsonl"
  got="$(head -n1 "$workdir/$type.jsonl" | jq -r '.payload | @base64d | fromjson | .predicateType')"
  [[ "$got" == "${predicate_types[$type]}" ]] || die "$type: unexpected predicate type $got"
done

log "checking provenance contents"
provenance="$(head -n1 "$workdir/slsaprovenance1.jsonl" | jq '.payload | @base64d | fromjson | .predicate')"
builder="$(jq -r '.runDetails.builder.id' <<<"$provenance")"
[[ "$builder" =~ $identity_re ]] || die "provenance builder.id $builder does not match $identity_re"

if [[ -n "${SOURCE_REPOSITORY:-}" ]]; then
  source_uri="$(jq -r '.buildDefinition.resolvedDependencies[0].uri' <<<"$provenance")"
  [[ "$source_uri" == "git+https://github.com/${SOURCE_REPOSITORY}@"* ]] \
    || die "provenance source $source_uri is not $SOURCE_REPOSITORY"
fi

packages="$(head -n1 "$workdir/spdxjson.jsonl" | jq '.payload | @base64d | fromjson | .predicate.packages | length')"

if [[ "${VERIFY_GH_ATTESTATIONS:-0}" == "1" ]]; then
  command -v gh >/dev/null || die "gh is required when VERIFY_GH_ATTESTATIONS=1"
  owner="${ref#*/}"
  owner="${owner%%/*}"
  log "verifying GitHub artifact attestations"
  gh attestation verify "oci://$ref" --owner "$owner" \
    --signer-workflow "MahyarNemati/supply-chain-pipeline/.github/workflows/supply-chain.yml" >/dev/null
fi

jq -n --arg ref "$ref" --arg builder "$builder" --argjson packages "$packages" \
  '{verified: true, image: $ref, builder: $builder, sbomPackages: $packages,
    attestations: ["spdxjson", "cyclonedx", "slsaprovenance1"]}'
