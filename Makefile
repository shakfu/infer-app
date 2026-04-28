BUILD_DIR := build
LLAMA_XCFRAMEWORK := thirdparty/llama.xcframework
LLAMA_FRAMEWORK := $(LLAMA_XCFRAMEWORK)/macos-arm64_x86_64/llama.framework
LLAMA_TAG := b8848
WHISPER_XCFRAMEWORK := thirdparty/whisper.xcframework
WHISPER_FRAMEWORK := $(WHISPER_XCFRAMEWORK)/macos-arm64_x86_64/whisper.framework
WHISPER_TAG := v1.8.4
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
.PHONY: fetch-llama fetch-whisper fetch-webassets fetch-sqlitevec fetch-python generate-icon
.PHONY: build-release bundle-release run-release

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
test:
	cd $(INFER_DIR) && swift test --skip ExternalTests

# External-system tests. Runs only suites whose name ends in
# `ExternalTests` — `QuartoExternalTests` today, more as they're added
# (real LLM / model-loading tests, real-network http tests, etc.).
# These auto-skip per-test when the external dependency is missing
# (e.g. Quarto not on PATH), so this target is safe to run on CI
# machines that don't install every external dep.
test-integration:
	cd $(INFER_DIR) && swift test --filter ExternalTests

# Run everything — fast suites + external suites in one pass. Useful
# pre-commit / pre-release. Slower than `make test` by however long
# the external suites take.
test-all:
	cd $(INFER_DIR) && swift test

# --- Infer app (SwiftPM + llama.framework + MLX) ---

$(LLAMA_XCFRAMEWORK):
	./scripts/fetch_llama_framework.sh $(LLAMA_TAG)

fetch-llama: $(LLAMA_XCFRAMEWORK)

$(WHISPER_XCFRAMEWORK):
	./scripts/fetch_whisper_framework.sh $(WHISPER_TAG)

fetch-whisper: $(WHISPER_XCFRAMEWORK)

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

build: $(LLAMA_XCFRAMEWORK) $(WHISPER_XCFRAMEWORK) $(SQLITEVEC_MARKER)
	xcodebuild $(INFER_XCODE_FLAGS) build

bundle: build $(INFER_DIR)/Resources/AppIcon.icns $(WEBASSETS_MARKER)
	rm -rf $(INFER_APP_BUNDLE)
	mkdir -p $(INFER_APP_BUNDLE)/Contents/MacOS
	mkdir -p $(INFER_APP_BUNDLE)/Contents/Resources
	mkdir -p $(INFER_APP_BUNDLE)/Contents/Frameworks
	cp $(INFER_BIN) $(INFER_APP_BUNDLE)/Contents/MacOS/Infer
	cp $(INFER_DIR)/Sources/Infer/Info.plist $(INFER_APP_BUNDLE)/Contents/Info.plist
	cp $(INFER_DIR)/Resources/AppIcon.icns $(INFER_APP_BUNDLE)/Contents/Resources/AppIcon.icns
	cp -R $(LLAMA_FRAMEWORK) $(INFER_APP_BUNDLE)/Contents/Frameworks/llama.framework
	cp -R $(WHISPER_FRAMEWORK) $(INFER_APP_BUNDLE)/Contents/Frameworks/whisper.framework
	cp -R $(WEBASSETS_DIR) $(INFER_APP_BUNDLE)/Contents/Resources/WebAssets
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
