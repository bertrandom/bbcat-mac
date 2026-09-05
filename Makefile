APP := build/bbcat.app
PREVIEW := $(APP)/Contents/PlugIns/bbcatPreview.appex
METADATA := $(APP)/Contents/Library/Spotlight/bbcat.mdimporter
THUMBNAIL_BINARY := build/thumbnail/bbcatThumbnail
RUST_LIB := RustBridge/target/release/libbbcat_bridge.a
# Keep this pinned to the bbcat version in RustBridge/Cargo.lock.
BBCAT_CLI_VERSION := 0.7.1
CLI_INSTALL_ROOT := build/bbcat-cli
CLI_TARGET_DIR := build/bbcat-cli-target
CLI_BINARY := $(CLI_INSTALL_ROOT)/bin/bbcat
BUNDLED_CLI := $(APP)/Contents/Helpers/bbcat
SWIFT_TEST_BINARY := build/tests/command-line-tool-installer-tests
METADATA_TEST_BINARY := build/tests/metadata-importer-tests
SWIFT_SOURCES := $(wildcard Sources/bbcat/*.swift)
THUMBNAIL_SOURCES := $(wildcard Sources/bbcatThumbnail/*.swift)
PREVIEW_SOURCES := $(wildcard Sources/bbcatPreview/*.swift) Sources/bbcat/ArtworkView.swift Sources/bbcat/Bridge.swift
METADATA_SOURCES := $(wildcard Sources/bbcatMetadata/*.m)
APP_ICON := Resources/bbcat.icns
BBCAT_LICENSE := Resources/BBCAT_LICENSE
THIRD_PARTY_LICENSES := Resources/THIRD_PARTY_LICENSES
ARCH := $(shell uname -m)
DEPLOYMENT_TARGET := 13.0

.PHONY: all bundle thumbnail-extensions run test clean

all: bundle

bundle: $(APP)/Contents/MacOS/bbcat $(BUNDLED_CLI) $(APP)/Contents/Resources/bbcat.icns $(APP)/Contents/Resources/BBCAT_LICENSE $(APP)/Contents/Resources/THIRD_PARTY_LICENSES thumbnail-extensions $(PREVIEW)/Contents/MacOS/bbcatPreview $(METADATA)/Contents/MacOS/bbcatMetadata
	codesign --force --sign - $(BUNDLED_CLI)
	for extension in $(APP)/Contents/PlugIns/bbcatThumbnail-*.appex; do \
		codesign --force --sign - --entitlements Resources/Thumbnail.entitlements "$$extension"; \
	done
	codesign --force --sign - --entitlements Resources/Thumbnail.entitlements $(PREVIEW)
	codesign --force --sign - $(METADATA)
	codesign --force --sign - $(APP)

$(RUST_LIB): Makefile RustBridge/Cargo.toml RustBridge/src/lib.rs RustBridge/include/bbcat_bridge.h
	MACOSX_DEPLOYMENT_TARGET=$(DEPLOYMENT_TARGET) cargo build --release --manifest-path RustBridge/Cargo.toml

$(CLI_BINARY): $(RUST_LIB) Makefile RustBridge/Cargo.lock
	MACOSX_DEPLOYMENT_TARGET=$(DEPLOYMENT_TARGET) CARGO_TARGET_DIR=$(CURDIR)/$(CLI_TARGET_DIR) \
		cargo install --locked --offline --force --version $(BBCAT_CLI_VERSION) --root $(CURDIR)/$(CLI_INSTALL_ROOT) bbcat

$(BUNDLED_CLI): $(CLI_BINARY)
	mkdir -p $(APP)/Contents/Helpers
	cp $(CLI_BINARY) $@

$(APP)/Contents/MacOS/bbcat: Makefile $(RUST_LIB) $(SWIFT_SOURCES) Resources/Info.plist
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ModuleCache \
	swiftc -module-cache-path $(CURDIR)/build/ModuleCache -target $(ARCH)-apple-macosx$(DEPLOYMENT_TARGET) \
		-swift-version 5 -O -whole-module-optimization \
		-import-objc-header RustBridge/include/bbcat_bridge.h \
		$(SWIFT_SOURCES) $(RUST_LIB) -framework AppKit -framework CoreServices -framework UniformTypeIdentifiers \
		-o $(APP)/Contents/MacOS/bbcat

$(APP_ICON): Resources/bbcat.svg Scripts/render-icon.swift
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ModuleCache \
		swift -module-cache-path $(CURDIR)/build/ModuleCache Scripts/render-icon.swift Resources/bbcat.svg $(APP_ICON)

$(APP)/Contents/Resources/bbcat.icns: $(APP_ICON)
	mkdir -p $(APP)/Contents/Resources
	cp $(APP_ICON) $@

$(APP)/Contents/Resources/THIRD_PARTY_LICENSES: $(THIRD_PARTY_LICENSES)
	mkdir -p $(APP)/Contents/Resources
	cp $(THIRD_PARTY_LICENSES) $@

$(APP)/Contents/Resources/BBCAT_LICENSE: $(BBCAT_LICENSE)
	mkdir -p $(APP)/Contents/Resources
	cp $(BBCAT_LICENSE) $@

$(THUMBNAIL_BINARY): Makefile $(RUST_LIB) $(THUMBNAIL_SOURCES)
	rm -f $(THUMBNAIL_BINARY)
	mkdir -p $(dir $(THUMBNAIL_BINARY))
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ModuleCache \
	swiftc -module-cache-path $(CURDIR)/build/ModuleCache -target $(ARCH)-apple-macosx$(DEPLOYMENT_TARGET) \
		-swift-version 5 -O -whole-module-optimization -parse-as-library -application-extension \
		-module-name bbcatThumbnail -import-objc-header RustBridge/include/bbcat_bridge.h \
		$(THUMBNAIL_SOURCES) $(RUST_LIB) -framework AppKit -framework QuickLookThumbnailing \
		-Xlinker -e -Xlinker _NSExtensionMain -o $(THUMBNAIL_BINARY)

thumbnail-extensions: $(THUMBNAIL_BINARY) Resources/ThumbnailInfo.plist Scripts/install-thumbnail-extensions.sh
	bash Scripts/install-thumbnail-extensions.sh $(APP) $(THUMBNAIL_BINARY) Resources/ThumbnailInfo.plist

$(PREVIEW)/Contents/MacOS/bbcatPreview: Makefile $(RUST_LIB) $(PREVIEW_SOURCES) Resources/PreviewInfo.plist
	rm -rf $(PREVIEW)
	mkdir -p $(PREVIEW)/Contents/MacOS
	cp Resources/PreviewInfo.plist $(PREVIEW)/Contents/Info.plist
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ModuleCache \
	swiftc -module-cache-path $(CURDIR)/build/ModuleCache -target $(ARCH)-apple-macosx$(DEPLOYMENT_TARGET) \
		-swift-version 5 -O -whole-module-optimization -parse-as-library -application-extension \
		-module-name bbcatPreview -import-objc-header RustBridge/include/bbcat_bridge.h \
		$(PREVIEW_SOURCES) $(RUST_LIB) -framework AppKit -framework QuickLookUI \
		-Xlinker -e -Xlinker _NSExtensionMain -o $(PREVIEW)/Contents/MacOS/bbcatPreview

$(METADATA)/Contents/MacOS/bbcatMetadata: Makefile $(RUST_LIB) $(METADATA_SOURCES) Resources/MetadataInfo.plist Resources/MetadataSchema.xml Resources/MetadataSchema.strings
	rm -rf $(METADATA)
	mkdir -p $(METADATA)/Contents/MacOS $(METADATA)/Contents/Resources
	cp Resources/MetadataInfo.plist $(METADATA)/Contents/Info.plist
	cp Resources/MetadataSchema.xml $(METADATA)/Contents/Resources/schema.xml
	cp Resources/MetadataSchema.strings $(METADATA)/Contents/Resources/schema.strings
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ModuleCache \
	clang -fobjc-arc -fmodules \
		-target $(ARCH)-apple-macosx$(DEPLOYMENT_TARGET) -O2 -bundle \
		-I RustBridge/include $(METADATA_SOURCES) $(RUST_LIB) \
		-framework Foundation -framework CoreServices \
		-o $(METADATA)/Contents/MacOS/bbcatMetadata

run: all
	open $(APP)

$(SWIFT_TEST_BINARY): Sources/bbcat/CommandLineToolInstaller.swift Tests/CommandLineToolInstaller/main.swift
	mkdir -p build/tests
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/build/ModuleCache \
		swiftc -module-cache-path $(CURDIR)/build/ModuleCache \
		-target $(ARCH)-apple-macosx$(DEPLOYMENT_TARGET) -swift-version 5 -O $^ -o $@

$(METADATA_TEST_BINARY): Tests/MetadataImporter/main.c
	mkdir -p build/tests
	clang -target $(ARCH)-apple-macosx$(DEPLOYMENT_TARGET) -O2 $< \
		-framework CoreServices -o $@

test: $(SWIFT_TEST_BINARY) $(METADATA_TEST_BINARY) $(METADATA)/Contents/MacOS/bbcatMetadata
	cargo test --manifest-path RustBridge/Cargo.toml
	$(SWIFT_TEST_BINARY)
	$(METADATA_TEST_BINARY) $(METADATA) RustBridge/tests/fixtures/basic.ans dev.bbcat.ansi-art

clean:
	cargo clean --manifest-path RustBridge/Cargo.toml
	rm -rf build
