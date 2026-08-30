APP_NAME := Voform
BUNDLE_ID := dev.knothhe.voform
CONFIGURATION ?= release
BUILD_DIR := .build/$(CONFIGURATION)
APP_DIR := dist/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MODULE_CACHE := $(CURDIR)/.build/ModuleCache
SIGNING_CONFIG := .voform-signing-identity
SIGNING_RESOLVER := Scripts/resolve-signing-identity.sh

.PHONY: all build run install clean signing-identity

all: build

build:
	@SIGN_IDENTITY="$(SIGN_IDENTITY)" SIGNING_CONFIG_FILE="$(SIGNING_CONFIG)" "$(SIGNING_RESOLVER)" >/dev/null
	mkdir -p "$(MODULE_CACHE)"
	SWIFTPM_MODULECACHE_OVERRIDE="$(MODULE_CACHE)" CLANG_MODULE_CACHE_PATH="$(MODULE_CACHE)" swift build --disable-sandbox -c $(CONFIGURATION)
	mkdir -p "$(CONTENTS_DIR)/MacOS" "$(CONTENTS_DIR)/Resources"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS_DIR)/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(CONTENTS_DIR)/Info.plist"
	@identity="$$(SIGN_IDENTITY="$(SIGN_IDENTITY)" SIGNING_CONFIG_FILE="$(SIGNING_CONFIG)" "$(SIGNING_RESOLVER)")"; \
		codesign --force --deep --timestamp=none --sign "$$identity" --entitlements Resources/Voform.entitlements "$(APP_DIR)"

signing-identity:
	@FORCE_SIGNING_IDENTITY_SELECTION=1 SIGN_IDENTITY="$(SIGN_IDENTITY)" SIGNING_CONFIG_FILE="$(SIGNING_CONFIG)" "$(SIGNING_RESOLVER)" >/dev/null

run: build
	open "$(APP_DIR)"

install: build
	ditto "$(APP_DIR)" "/Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf "$(APP_DIR)"
