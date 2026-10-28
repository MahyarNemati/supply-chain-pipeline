#!/usr/bin/env bash
# Runs example/verify.sh against a stubbed cosign that returns canned
# attestation envelopes, covering the accept path and the main reject paths.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verify="$root/example/verify.sh"
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

ref="ghcr.io/acme/app@sha256:$(printf 'a%.0s' {1..64})"
good_builder="https://github.com/MahyarNemati/supply-chain-pipeline/.github/workflows/supply-chain.yml@refs/heads/main"

cat >"$stub_dir/cosign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
type=""
while (($#)); do
  case "$1" in
    --type) type="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ "${STUB_FAIL_SIGNATURE:-0}" == "1" && "$cmd" == "verify" ]] && exit 1
[[ "$cmd" == "verify" ]] && { echo '[{"critical":{}}]'; exit 0; }
case "$type" in
  spdxjson) statement='{"predicateType":"https://spdx.dev/Document","predicate":{"spdxVersion":"SPDX-2.3","packages":[{},{},{}]}}' ;;
  cyclonedx) statement='{"predicateType":"https://cyclonedx.org/bom","predicate":{"bomFormat":"CycloneDX"}}' ;;
  slsaprovenance1)
    statement="$(jq -nc --arg b "$STUB_BUILDER" --arg src "$STUB_SOURCE" \
      '{predicateType:"https://slsa.dev/provenance/v1",predicate:{runDetails:{builder:{id:$b}},buildDefinition:{resolvedDependencies:[{uri:$src}]}}}')" ;;
  *) exit 2 ;;
esac
jq -nc --arg p "$(printf '%s' "$statement" | base64 -w0)" '{payloadType:"application/vnd.in-toto+json",payload:$p}'
STUB
chmod +x "$stub_dir/cosign"

failures=0
expect_ok() {
  local desc="$1"; shift
  local out
  if out="$(env "$@" PATH="$stub_dir:$PATH" "$verify" "$ref" 2>/dev/null)" \
     && jq -e '.verified and .sbomPackages == 3' >/dev/null <<<"$out"; then
    echo "ok   $desc"
  else
    echo "FAIL $desc"
    failures=$((failures + 1))
  fi
}
expect_fail() {
  local desc="$1"; shift
  if env "$@" PATH="$stub_dir:$PATH" "$verify" "$ref" >/dev/null 2>&1; then
    echo "FAIL $desc"
    failures=$((failures + 1))
  else
    echo "ok   $desc"
  fi
}

expect_ok "accepts image signed by the reusable workflow" \
  STUB_BUILDER="$good_builder" STUB_SOURCE="git+https://github.com/acme/app@refs/heads/main"

expect_ok "accepts when source repository matches" \
  STUB_BUILDER="$good_builder" STUB_SOURCE="git+https://github.com/acme/app@refs/heads/main" SOURCE_REPOSITORY=acme/app

expect_fail "rejects provenance from another builder" \
  STUB_BUILDER="https://github.com/evil/fork/.github/workflows/supply-chain.yml@refs/heads/main" STUB_SOURCE="git+https://github.com/acme/app@refs/heads/main"

expect_fail "rejects provenance from a feature branch of the pipeline" \
  STUB_BUILDER="${good_builder%main}feature" STUB_SOURCE="git+https://github.com/acme/app@refs/heads/main"

expect_fail "rejects mismatched source repository" \
  STUB_BUILDER="$good_builder" STUB_SOURCE="git+https://github.com/acme/other@refs/heads/main" SOURCE_REPOSITORY=acme/app

expect_fail "rejects when signature verification fails" \
  STUB_BUILDER="$good_builder" STUB_SOURCE="git+https://github.com/acme/app@refs/heads/main" STUB_FAIL_SIGNATURE=1

if PATH="$stub_dir:$PATH" "$verify" "ghcr.io/acme/app:latest" >/dev/null 2>&1; then
  echo "FAIL rejects tag references"
  failures=$((failures + 1))
else
  echo "ok   rejects tag references"
fi

if ((failures)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
