APP_NAME = Atlas
BUNDLE_ID = com.atlas.app
EXECUTABLE_NAME = Atlas

APP_BUNDLE = .build/$(APP_NAME).app
BIN_DIR := $(shell swift build -c release --show-bin-path)
INSTALL_DIR ?= /Applications

build:
	swift build -c release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BIN_DIR)/$(EXECUTABLE_NAME) $(APP_BUNDLE)/Contents/MacOS/$(EXECUTABLE_NAME)
	cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	# Live-verified against the release accessor: candidates are
	# Bundle.main.resourceURL (Contents/Resources) before bundleURL, and the
	# app launches without fatalError only with the bundle in Resources.
	find $(BIN_DIR) -maxdepth 1 -name "*.bundle" -type d -exec cp -R {} $(APP_BUNDLE)/Contents/Resources/ \;
	codesign --force --deep --sign - --entitlements Atlas.entitlements $(APP_BUNDLE)

install: build
	@if pgrep -x $(EXECUTABLE_NAME) > /dev/null; then \
		echo "✗ Atlas è in esecuzione: chiudila e riprova."; exit 1; \
	fi
	@# Staging directory as a sibling of the destination, replaced atomically;
	@# the old bundle is removed only after the new one is verified and moved.
	rm -rf "$(INSTALL_DIR)/.Atlas.app.staging"
	mkdir -p "$(INSTALL_DIR)/.Atlas.app.staging"
	cp -R $(APP_BUNDLE) "$(INSTALL_DIR)/.Atlas.app.staging/$(APP_NAME).app"
	@test -x "$(INSTALL_DIR)/.Atlas.app.staging/$(APP_NAME).app/Contents/MacOS/$(EXECUTABLE_NAME)" \
		&& test -f "$(INSTALL_DIR)/.Atlas.app.staging/$(APP_NAME).app/Contents/Info.plist" \
		&& codesign --verify --deep --strict "$(INSTALL_DIR)/.Atlas.app.staging/$(APP_NAME).app"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	mv "$(INSTALL_DIR)/.Atlas.app.staging/$(APP_NAME).app" "$(INSTALL_DIR)/$(APP_NAME).app"
	rm -rf "$(INSTALL_DIR)/.Atlas.app.staging"
	@echo "✓ Atlas.app installato in $(INSTALL_DIR)/$(APP_NAME).app"

run: build
	open $(APP_BUNDLE)

clean:
	rm -rf $(APP_BUNDLE)
	swift package clean
