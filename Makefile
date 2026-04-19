BUILD_DIR := build
INFER_APP_BUNDLE := $(BUILD_DIR)/Infer.app
LLAMA_XCFRAMEWORK := thirdparty/llama.xcframework
LLAMA_FRAMEWORK := $(LLAMA_XCFRAMEWORK)/macos-arm64_x86_64/llama.framework
LLAMA_TAG := b8848
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

.PHONY: all build clean
.PHONY: build-infer bundle-infer run-infer fetch-llama

all: build

build: build-infer

clean:
	rm -rf $(BUILD_DIR)

# --- Infer app (SwiftPM + llama.framework + MLX) ---

$(LLAMA_XCFRAMEWORK):
	./scripts/fetch_llama_framework.sh $(LLAMA_TAG)

fetch-llama: $(LLAMA_XCFRAMEWORK)

build-infer: $(LLAMA_XCFRAMEWORK)
	xcodebuild $(INFER_XCODE_FLAGS) build

bundle-infer: build-infer
	rm -rf $(INFER_APP_BUNDLE)
	mkdir -p $(INFER_APP_BUNDLE)/Contents/MacOS
	mkdir -p $(INFER_APP_BUNDLE)/Contents/Resources
	mkdir -p $(INFER_APP_BUNDLE)/Contents/Frameworks
	cp $(INFER_BIN) $(INFER_APP_BUNDLE)/Contents/MacOS/Infer
	cp $(INFER_DIR)/Sources/Infer/Info.plist $(INFER_APP_BUNDLE)/Contents/Info.plist
	cp -R $(LLAMA_FRAMEWORK) $(INFER_APP_BUNDLE)/Contents/Frameworks/llama.framework
	@for bundle in $(INFER_PRODUCT_DIR)/*.bundle; do \
		[ -e "$$bundle" ] || continue; \
		cp -R "$$bundle" $(INFER_APP_BUNDLE)/Contents/Resources/; \
	done
	@echo "Built $(INFER_APP_BUNDLE)"

run-infer: bundle-infer
	open $(INFER_APP_BUNDLE)
