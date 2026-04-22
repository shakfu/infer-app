BUILD_DIR := build
INFER_APP_BUNDLE := $(BUILD_DIR)/Infer.app
LLAMA_XCFRAMEWORK := thirdparty/llama.xcframework
LLAMA_FRAMEWORK := $(LLAMA_XCFRAMEWORK)/macos-arm64_x86_64/llama.framework
LLAMA_TAG := b8848
WHISPER_XCFRAMEWORK := thirdparty/whisper.xcframework
WHISPER_FRAMEWORK := $(WHISPER_XCFRAMEWORK)/macos-arm64_x86_64/whisper.framework
WHISPER_TAG := v1.8.4
WEBASSETS_DIR := thirdparty/webassets
WEBASSETS_MARKER := $(WEBASSETS_DIR)/katex/katex.min.js
INFER_DIR := projects/infer
INFER_BUILD_DIR := $(BUILD_DIR)/infer-xcode
INFER_CONFIG := Debug
INFER_XCODE_FLAGS := -workspace $(INFER_DIR) -scheme Infer \
	-destination 'platform=macOS,arch=arm64' \
	-configuration $(INFER_CONFIG) \
	-derivedDataPath $(CURDIR)/$(INFER_BUILD_DIR) \
	-skipMacroValidation
INFER_PRODUCT_DIR := $(INFER_BUILD_DIR)/Build/Products/$(INFER_CONFIG)
INFER_BIN := $(INFER_PRODUCT_DIR)/Infer

.PHONY: all build clean clean-infer clean-mlx-cache test
.PHONY: build-infer bundle-infer run-infer fetch-llama fetch-whisper fetch-webassets generate-icon

all: build

build: build-infer

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

# Runs the pure-Swift InferCore test suite under swift-test. Does not require
# the Metal Toolchain or the fetched llama/whisper xcframeworks — the Infer
# executable target is not built here, only InferCore + its tests.
test:
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

build-infer: $(LLAMA_XCFRAMEWORK) $(WHISPER_XCFRAMEWORK)
	xcodebuild $(INFER_XCODE_FLAGS) build

bundle-infer: build-infer $(INFER_DIR)/Resources/AppIcon.icns $(WEBASSETS_MARKER)
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

run-infer: bundle-infer
	open $(INFER_APP_BUNDLE)

# Regenerate the placeholder app icon. The .icns is committed, so this only
# needs to run when the design changes. Requires /usr/bin/iconutil (ships
# with macOS).
$(INFER_DIR)/Resources/AppIcon.icns: scripts/generate_app_icon.swift
	swift scripts/generate_app_icon.swift

generate-icon: $(INFER_DIR)/Resources/AppIcon.icns
