OUTPUT_DIR ?= $(CURDIR)/fleet
KUSTOMIZE ?= kustomize
YQ ?= yq
DASEL ?= dasel
PYTHON ?= python3
FIX_TOML ?= $(CURDIR)/bin/fix-toml-multiline.py
FLEET_REMOTE ?= fleet
FLEET_BRANCH ?= flox-subtree

SHELL := bash
.SHELLFLAGS := -exu -o pipefail -c
.ONESHELL:

.PRECIOUS: $(OUTPUT_DIR)/%/.flox/env $(OUTPUT_DIR)/%/.flox/run $(BUILD_YAML)

FLOX_ENV_FILES := $(filter-out kustomization.yaml,$(wildcard *.yaml))
FLOX_ENV_NAMES := $(basename $(notdir $(FLOX_ENV_FILES)))
KUSTOMIZE_SOURCES := kustomization.yaml $(FLOX_ENV_FILES)
BUILD_YAML := $(OUTPUT_DIR)/.kustomize/flox.yaml

MANIFEST_TARGETS := $(addprefix $(OUTPUT_DIR)/,$(addsuffix /.flox/env/manifest.toml,$(FLOX_ENV_NAMES)))
ENV_JSON_TARGETS := $(addprefix $(OUTPUT_DIR)/,$(addsuffix /.flox/env.json,$(FLOX_ENV_NAMES)))
RENDER_TARGETS := $(MANIFEST_TARGETS) $(ENV_JSON_TARGETS)

.PHONY: all render check-tools fleet-remote fleet-pull fleet-push

all: render

render: check-tools
	$(MAKE) $(RENDER_TARGETS)

check-tools:
	missing="";
	for cmd in $(KUSTOMIZE) $(YQ) $(DASEL); do
	  if ! command -v $$cmd >/dev/null 2>&1; then
	    missing="$$missing $$cmd";
	  fi;
	done;
	if [[ -n "$$missing" ]]; then
	  echo "Missing required commands:$$missing" >&2;
	  exit 1;
	fi;

$(BUILD_YAML): $(KUSTOMIZE_SOURCES)
	mkdir -p "$(dir $@)"
	$(KUSTOMIZE) build $(CURDIR) > "$@"

$(OUTPUT_DIR)/%/.flox/env:
	mkdir -p "$@"

$(OUTPUT_DIR)/%/.flox/run:
	mkdir -p "$@"

$(OUTPUT_DIR)/%/.flox/env/manifest.toml: $(BUILD_YAML) | $(OUTPUT_DIR)/%/.flox/env $(OUTPUT_DIR)/%/.flox/run
	$(YQ) eval "select(.kind == \"FloxEnvironment\" and .metadata.name == \"$*\") | .spec.manifest" "$(BUILD_YAML)" | \
		$(DASEL) -r yaml -w toml -f /dev/stdin > "$@"
	$(PYTHON) "$(FIX_TOML)" "$@"

$(OUTPUT_DIR)/%/.flox/env.json: $(BUILD_YAML) | $(OUTPUT_DIR)/%/.flox/env $(OUTPUT_DIR)/%/.flox/run
	$(YQ) eval "select(.kind == \"FloxEnvironment\" and .metadata.name == \"$*\") | .spec.env" "$(BUILD_YAML)" | \
		$(DASEL) -r yaml -w json -f /dev/stdin > "$@"

fleet-remote:
	@if ! git remote get-url "$(FLEET_REMOTE)" >/dev/null 2>&1; then \
	  git remote add "$(FLEET_REMOTE)" git@github.com:nxmatic/fleet-manifests.git; \
	fi

fleet-pull: fleet-remote
	git subtree pull --prefix="$(OUTPUT_DIR)" "$(FLEET_REMOTE)" "$(FLEET_BRANCH)" --squash

fleet-push: fleet-remote render
	@if ! git -C "$(CURDIR)" diff --quiet HEAD -- "$(OUTPUT_DIR)"; then \
	  echo "Uncommitted changes detected under $(OUTPUT_DIR). Please commit or stash them before pushing." >&2; \
	  exit 1; \
	fi
	@untracked="$$(git -C "$(CURDIR)" ls-files --others -- "$(OUTPUT_DIR)" --exclude-standard)"; \
	if [[ -n "$$untracked" ]]; then \
	  echo "Untracked files detected under $(OUTPUT_DIR). Please add or clean them before pushing." >&2; \
	  exit 1; \
	fi
	@split_sha="$$(git -C "$(CURDIR)" subtree split --prefix="$(OUTPUT_DIR)" HEAD)"; \
	remote_sha="$$(git -C "$(CURDIR)" ls-remote --heads "$(FLEET_REMOTE)" "$(FLEET_BRANCH)" | awk '{print $$1}')" || true; \
	if [[ -n "$$remote_sha" && "$$split_sha" == "$$remote_sha" ]]; then \
	  echo "No new fleet revisions to push; skipping subtree push."; \
	else \
	  git -C "$(CURDIR)" subtree push --prefix="$(OUTPUT_DIR)" "$(FLEET_REMOTE)" "$(FLEET_BRANCH)"; \
	fi
