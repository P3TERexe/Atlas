APP_NAME = Atlas
BUNDLE_ID = com.atlas.app
EXECUTABLE_NAME = Atlas

build:
	swift build -c release
	$(eval BIN_DIR := $(shell swift build -c release --show-bin-path))
	mkdir -p .build/$(APP_NAME).app/Contents/MacOS
	mkdir -p .build/$(APP_NAME).app/Contents/Resources
	cp $(BIN_DIR)/$(EXECUTABLE_NAME) .build/$(APP_NAME).app/Contents/MacOS/$(EXECUTABLE_NAME)
	cp Info.plist .build/$(APP_NAME).app/Contents/Info.plist
	codesign --force --deep --sign - --entitlements Atlas.entitlements .build/$(APP_NAME).app

install: build
	cp -R .build/$(APP_NAME).app /Applications/$(APP_NAME).app
	@echo "✓ Atlas.app installato con successo in /Applications/Atlas.app"

run: build
	open .build/$(APP_NAME).app

clean:
	rm -rf .build/$(APP_NAME).app
	swift package clean
