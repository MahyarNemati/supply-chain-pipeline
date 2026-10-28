#!/usr/bin/env bash
# Emits a SLSA v1 provenance predicate for a container image built by the
# reusable workflow. Inputs come from the GitHub Actions environment plus a few
# PROV_* variables set by the caller. Output is written to stdout.
set -euo pipefail

require() {
  local missing=()
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if ((${#missing[@]})); then
    echo "provenance.sh: missing required environment: ${missing[*]}" >&2
    exit 64
  fi
}

require GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_REPOSITORY_ID GITHUB_REPOSITORY_OWNER_ID \
  GITHUB_SHA GITHUB_REF GITHUB_EVENT_NAME GITHUB_RUN_ID GITHUB_RUN_ATTEMPT \
  PROV_BUILDER_ID PROV_STARTED_ON PROV_CONTEXT PROV_DOCKERFILE PROV_PLATFORMS

finished_on="${PROV_FINISHED_ON:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

jq -n \
  --arg server "$GITHUB_SERVER_URL" \
  --arg repo "$GITHUB_REPOSITORY" \
  --arg repo_id "$GITHUB_REPOSITORY_ID" \
  --arg owner_id "$GITHUB_REPOSITORY_OWNER_ID" \
  --arg sha "$GITHUB_SHA" \
  --arg ref "$GITHUB_REF" \
  --arg event "$GITHUB_EVENT_NAME" \
  --arg run_id "$GITHUB_RUN_ID" \
  --arg attempt "$GITHUB_RUN_ATTEMPT" \
  --arg runner_env "${RUNNER_ENVIRONMENT:-unknown}" \
  --arg builder "$PROV_BUILDER_ID" \
  --arg caller_workflow "${GITHUB_WORKFLOW_REF:-}" \
  --arg context "$PROV_CONTEXT" \
  --arg dockerfile "$PROV_DOCKERFILE" \
  --arg platforms "$PROV_PLATFORMS" \
  --arg build_args "${PROV_BUILD_ARGS:-}" \
  --arg started "$PROV_STARTED_ON" \
  --arg finished "$finished_on" \
  '{
    buildDefinition: {
      buildType: "https://github.com/MahyarNemati/supply-chain-pipeline/buildtypes/container/v1",
      externalParameters: {
        source: { repository: ($server + "/" + $repo), ref: $ref },
        workflow: $caller_workflow,
        context: $context,
        dockerfile: $dockerfile,
        platforms: ($platforms | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))),
        buildArgs: ($build_args | split("\n") | map(select(length > 0)))
      },
      internalParameters: {
        github: {
          event_name: $event,
          repository_id: $repo_id,
          repository_owner_id: $owner_id,
          runner_environment: $runner_env
        }
      },
      resolvedDependencies: [
        {
          uri: ("git+" + $server + "/" + $repo + "@" + $ref),
          digest: { gitCommit: $sha }
        }
      ]
    },
    runDetails: {
      builder: { id: $builder },
      metadata: {
        invocationId: ($server + "/" + $repo + "/actions/runs/" + $run_id + "/attempts/" + $attempt),
        startedOn: $started,
        finishedOn: $finished
      }
    }
  }'
