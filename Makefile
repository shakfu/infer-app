BUILD_DIR := build
# Combined ggml-stack: one Ggml.xcframework shipping libggml*.dylib +
# thin LlamaCpp / Whisper / StableDiffusion frameworks layered on top.
# Replaces the prior separate llama.xcframework + whisper.xcframework
# from upstream releases (parked under thirdparty/_old/ for reference).
# Fetched together from one GitHub release; bump $(STACK_VERSION) and
# rerun `make fetch-stack` to upgrade.
STACK_VERSION := 0.2.14
GGML_XCFRAMEWORK := thirdparty/Ggml.xcframework
GGML_FRAMEWORK := $(GGML_XCFRAMEWORK)/macos-arm64/Ggml.framework
LLAMACPP_XCFRAMEWORK := thirdparty/LlamaCpp.xcframework
LLAMACPP_FRAMEWORK := $(LLAMACPP_XCFRAMEWORK)/macos-arm64/LlamaCpp.framework
WHISPER_XCFRAMEWORK := thirdparty/Whisper.xcframework
WHISPER_FRAMEWORK := $(WHISPER_XCFRAMEWORK)/macos-arm64/Whisper.framework
SD_XCFRAMEWORK := thirdparty/StableDiffusion.xcframework
SD_FRAMEWORK := $(SD_XCFRAMEWORK)/macos-arm64/StableDiffusion.framework
WEBASSETS_DIR := thirdparty/webassets
WEBASSETS_MARKER := $(WEBASSETS_DIR)/katex/katex.min.js
SQLITEVEC_DIR := thirdparty/SQLiteVec
SQLITEVEC_MARKER := $(SQLITEVEC_DIR)/Package.swift
SQLITEVEC_TAG := 0.0.14
INFER_DIR := projects/infer
INFER_BUILD_DIR := $(BUILD_DIR)/infer-xcode

# Xcode build configuration. Override via `make build INFER_CONFIG=Release`
# or use the dedicated *-release convenience targets below. Debug is the
# default because it's what active development wants; Release is for
# distribution-shaped local builds (optimized, stripped).
INFER_CONFIG := Debug

# Bundles are grouped by config: `build/Debug/Infer.app` vs
# `build/Release/Infer.app`. Same .app filename in both so Finder /
# Spotlight / Dock behave identically for either; switching configs
# doesn't force the other's bundle to be rebuilt.
INFER_APP_BUNDLE := $(BUILD_DIR)/$(INFER_CONFIG)/Infer.app

INFER_XCODE_FLAGS := -workspace $(INFER_DIR) -scheme Infer \
	-destination 'platform=macOS,arch=arm64' \
	-configuration $(INFER_CONFIG) \
	-derivedDataPath $(CURDIR)/$(INFER_BUILD_DIR) \
	-skipMacroValidation
INFER_PRODUCT_DIR := $(INFER_BUILD_DIR)/Build/Products/$(INFER_CONFIG)
INFER_BIN := $(INFER_PRODUCT_DIR)/Infer

.PHONY: all build bundle run clean clean-infer clean-mlx-cache test
.PHONY: fetch-stack fetch-webassets fetch-sqlitevec fetch-python generate-icon
.PHONY: build-release bundle-release run-release
.PHONY: plugins-gen plugins-gen-check

all: build

clean:
	rm -rf $(BUILD_DIR)

# Remove only the xcodebuild derived-data for the Infer scheme. Faster
# than `clean` when you want a fresh build without also blowing away the
# bundled .app.
clean-infer:
	rm -rf $(INFER_BUILD_DIR)

# Delete the Hugging Face cache (MLX model downloads). Grows unbounded —
# 20 GB+ after heavy experimentation. Requires explicit confirmation since
# re-downloading can be slow and bandwidth-costly.
clean-mlx-cache:
	@dir="$${HF_HOME:-$$HOME/.cache/huggingface}/hub"; \
	if [ ! -d "$$dir" ]; then \
		echo "No HF cache found at $$dir"; \
		exit 0; \
	fi; \
	size=$$(du -sh "$$dir" 2>/dev/null | awk '{print $$1}'); \
	printf "This will delete %s (%s). Continue? [y/N] " "$$dir" "$$size"; \
	read ans; \
	case "$$ans" in \
		[yY]|[yY][eE][sS]) rm -rf "$$dir"; echo "Removed $$dir";; \
		*) echo "Aborted.";; \
	esac

# Fast test path. Skips suites whose name ends in `ExternalTests` —
# those hit real binaries / network / models and are run via
# `make test-integration` instead. Does not require the Metal Toolchain
# or the fetched llama/whisper xcframeworks — the Infer executable
# target is not built here, only the library targets and their tests.
# Regenerate plugin glue (Package.swift marker sections + GeneratedPlugins.swift)
# from `projects/plugins/plugins.json`. Idempotent — re-running is a no-op when
# nothing changed. `build` depends on this so a stale Package.swift never reaches
# xcodebuild.
plugins-gen:
	./scripts/gen_plugins.py

# CI guard: regenerate, then assert the working tree is clean. Catches the
# "edited plugins.json, forgot to regenerate" case in review rather than at
# someone else's build.
plugins-gen-check: plugins-gen
	@if ! git diff --quiet -- projects/infer/Package.swift projects/infer/Sources/Infer/GeneratedPlugins.swift; then \
		echo "error: generated plugin files are stale; run 'make plugins-gen' and commit the result" >&2; \
		git --no-pager diff -- projects/infer/Package.swift projects/infer/Sources/Infer/GeneratedPlugins.swift >&2; \
		exit 1; \
	fi

test: plugins-gen
	cd $(INFER_DIR) && swift test --skip ExternalTests
	cd projects/plugin-api && swift test --skip ExternalTests
	@for plugin_pkg in projects/plugins/plugin_*; do \
		if [ -f "$$plugin_pkg/Package.swift" ]; then \
			echo "==> swift test --skip ExternalTests in $$plugin_pkg"; \
			(cd "$$plugin_pkg" && swift test --skip ExternalTests) || exit 1; \
		fi; \
	done

# External-system tests. Runs only suites whose name ends in
# `ExternalTests` — `QuartoExternalTests` today, more as they're added
# (real LLM / model-loading tests, real-network http tests, etc.).
# These auto-skip per-test when the external dependency is missing
# (e.g. Quarto not on PATH), so this target is safe to run on CI
# machines that don't install every external dep.
test-integration:
	cd $(INFER_DIR) && swift test --filter ExternalTests
	@for plugin_pkg in projects/plugins/plugin_*; do \
		if [ -f "$$plugin_pkg/Package.swift" ]; then \
			echo "==> swift test --filter ExternalTests in $$plugin_pkg"; \
			(cd "$$plugin_pkg" && swift test --filter ExternalTests) || exit 1; \
		fi; \
	done

# Run everything — fast suites + external suites in one pass. Useful
# pre-commit / pre-release. Slower than `make test` by however long
# the external suites take.
test-all:
	cd $(INFER_DIR) && swift test

# --- Infer app (SwiftPM + ggml-stack frameworks + MLX) ---

# All four xcframeworks are produced and released together. The fetch
# script downloads a single release zip and lays them out in thirdparty/.
# A version-stamped marker file gates the script so bumping
# $(STACK_VERSION) invalidates the install and triggers a re-fetch.
# (Make 3.81 — what ships with macOS — predates grouped targets, so the
# common idiom of "one rule with multiple outputs" is encoded as a
# marker file the per-framework targets depend on.)
STACK_MARKER := thirdparty/.stack-$(STACK_VERSION)

$(STACK_MARKER):
	./scripts/fetch_combined_framework.sh $(STACK_VERSION)
	@touch $@

$(GGML_XCFRAMEWORK): $(STACK_MARKER)
$(LLAMACPP_XCFRAMEWORK): $(STACK_MARKER)
$(WHISPER_XCFRAMEWORK): $(STACK_MARKER)
$(SD_XCFRAMEWORK): $(STACK_MARKER)

fetch-stack: $(STACK_MARKER)

$(WEBASSETS_MARKER):
	./scripts/fetch_webassets.sh

fetch-webassets: $(WEBASSETS_MARKER)

# Vendored SwiftPM dependency with local patches. Unlike the llama and
# whisper xcframeworks (prebuilt binaries), SQLiteVec is source we
# clone from upstream and patch — see docs/patches/sqlitevec.md for
# the full rationale on why each patch exists. Bump $(SQLITEVEC_TAG)
# to upgrade; rerun this target to re-clone and re-apply.
$(SQLITEVEC_MARKER):
	./scripts/fetch_sqlitevec.sh $(SQLITEVEC_TAG)

fetch-sqlitevec: $(SQLITEVEC_MARKER)

# Optional plugin. Builds CPython + a curated set of pip packages (default:
# openai, anthropic) into thirdparty/Python.framework via scripts/buildpy.py.
# The bundle rule copies the framework if present and skips otherwise, so
# Infer.app builds and runs without ever invoking this target. Override the
# package set with PY_PKGS, e.g.:
#   make fetch-python PY_PKGS="openai anthropic pandas matplotlib"
fetch-python:
	./scripts/fetch_python_framework.sh

build: $(GGML_XCFRAMEWORK) $(LLAMACPP_XCFRAMEWORK) $(WHISPER_XCFRAMEWORK) $(SQLITEVEC_MARKER) plugins-gen
	xcodebuild $(INFER_XCODE_FLAGS) build

bundle: build $(INFER_DIR)/Resources/AppIcon.icns $(WEBASSETS_MARKER)
	rm -rf $(INFER_APP_BUNDLE)
	mkdir -p $(INFER_APP_BUNDLE)/Contents/MacOS
	mkdir -p $(INFER_APP_BUNDLE)/Contents/Resources
	mkdir -p $(INFER_APP_BUNDLE)/Contents/Frameworks
	cp $(INFER_BIN) $(INFER_APP_BUNDLE)/Contents/MacOS/Infer
	cp $(INFER_DIR)/Sources/Infer/Info.plist $(INFER_APP_BUNDLE)/Contents/Info.plist
	cp $(INFER_DIR)/Resources/AppIcon.icns $(INFER_APP_BUNDLE)/Contents/Resources/AppIcon.icns
	cp -R $(GGML_FRAMEWORK) $(INFER_APP_BUNDLE)/Contents/Frameworks/Ggml.framework
	cp -R $(LLAMACPP_FRAMEWORK) $(INFER_APP_BUNDLE)/Contents/Frameworks/LlamaCpp.framework
	cp -R $(WHISPER_FRAMEWORK) $(INFER_APP_BUNDLE)/Contents/Frameworks/Whisper.framework
	cp -R $(WEBASSETS_DIR) $(INFER_APP_BUNDLE)/Contents/Resources/WebAssets
	@if [ -d "thirdparty/Python.framework" ]; then \
		echo "  bundling Python.framework"; \
		rm -rf "$(INFER_APP_BUNDLE)/Contents/Frameworks/Python.framework"; \
		cp -R "thirdparty/Python.framework" "$(INFER_APP_BUNDLE)/Contents/Frameworks/Python.framework"; \
	else \
		echo "  Python.framework not present (run 'make fetch-python' to opt in to plugin_python_tools)"; \
	fi
	@for bundle in $(INFER_PRODUCT_DIR)/*.bundle; do \
		[ -e "$$bundle" ] || continue; \
		cp -R "$$bundle" $(INFER_APP_BUNDLE)/Contents/Resources/; \
	done
	@echo "Built $(INFER_APP_BUNDLE)"

run: bundle
	open $(INFER_APP_BUNDLE)

# --- Release-configuration shortcuts ---
#
# These recursively invoke the corresponding Debug target with
# `INFER_CONFIG=Release` so the same build logic drives both configs —
# one set of rules, two configurations. The Release bundle lives at
# `build/Release/Infer.app` (distinct from the Debug `build/Debug/Infer.app`)
# so both coexist; switching configs doesn't force a full rebuild of
# the other side.
#
# Use these when you want an optimized local build for perf testing,
# distribution dry-runs, or "feels slower in Debug than it should"
# diagnosis. The xcodebuild Release config enables -O optimizations
# and strips debug symbols by default; no extra flags here are needed.

build-release:
	$(MAKE) build INFER_CONFIG=Release

bundle-release:
	$(MAKE) bundle INFER_CONFIG=Release

run-release:
	$(MAKE) run INFER_CONFIG=Release

# Regenerate the placeholder app icon. The .icns is committed, so this only
# needs to run when the design changes. Requires /usr/bin/iconutil (ships
# with macOS).
$(INFER_DIR)/Resources/AppIcon.icns: scripts/generate_app_icon.swift
	swift scripts/generate_app_icon.swift

generate-icon: $(INFER_DIR)/Resources/AppIcon.icns
