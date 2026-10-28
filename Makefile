SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

IMAGE ?= ghcr.io/mahyarnemati/digest-service
VERSION ?= dev
GOBIN ?= $(shell go env GOPATH)/bin
CRD_SCHEMAS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

.PHONY: help
help: ## Show targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

.PHONY: test
test: test-go test-scripts ## Run all tests

.PHONY: test-go
test-go: ## Go unit tests with the race detector
	cd example && go test -race -count=1 ./...

.PHONY: test-scripts
test-scripts: ## Provenance generator and verify script tests
	tests/provenance_test.sh
	tests/verify_test.sh

.PHONY: lint
lint: ## actionlint, shellcheck, yamllint, go vet, staticcheck, golangci-lint
	$(GOBIN)/actionlint
	shellcheck example/verify.sh .github/actions/sign-attest/provenance.sh tests/*.sh
	yamllint --strict .
	cd example && go vet ./... && $(GOBIN)/staticcheck ./... && golangci-lint run ./...

.PHONY: policy
policy: ## Validate the admission policy against the Kyverno CRD schema
	$(GOBIN)/kubeconform -strict -summary -schema-location default -schema-location '$(CRD_SCHEMAS)' example/policy

.PHONY: image
image: ## Build the example image locally
	docker build -t $(IMAGE):$(VERSION) --build-arg VERSION=$(VERSION) example

.PHONY: verify
verify: ## Verify a published image: make verify REF=ghcr.io/...@sha256:...
	@test -n "$(REF)" || { echo "usage: make verify REF=<image@digest>"; exit 64; }
	example/verify.sh "$(REF)"

.PHONY: tools
tools: ## Install Go-based linters
	go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
	go install honnef.co/go/tools/cmd/staticcheck@v0.6.1
	go install github.com/yannh/kubeconform/cmd/kubeconform@v0.8.0
	go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.8.0
