# Photon — developer workflow.
#
# The Flutter macOS target needs Xcode. If xcode-select points at the
# Command Line Tools rather than a full Xcode install, flutter is pointed at
# the system Xcode via DEVELOPER_DIR (overridable: make XCODE_DIR=... run).
XCODE_ACTIVE := $(shell xcode-select -p 2>/dev/null)
ifneq ($(findstring CommandLineTools,$(XCODE_ACTIVE)),)
  ifneq ($(XCODE_DIR),)
    export DEVELOPER_DIR := $(XCODE_DIR)
  else
    export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
  endif
endif

APP_DIR   := app
PHOTON    := build/photon
PKGS      := ./...
ROOT      := $(CURDIR)
JAVA_HOME ?= /opt/homebrew/opt/openjdk@17

# Where install-linux puts the app. Defaults to a user-local prefix so the
# install needs no root; override for a system-wide install, e.g.
# `sudo make install-linux PREFIX=/usr/local`.
PREFIX    ?= $(HOME)/.local

# Immutable tag for the runtime files install-linux deploys. Each install goes
# into its own <PREFIX>/lib/photon/versions/<BUILD_TAG>/ directory and a
# 'current' symlink is swapped in afterwards. Installed files are never
# rewritten in place, so an app still running from a previous install keeps its
# original inodes and cannot fault on a truncated mapping (the SIGBUS crash).
BUILD_TAG ?= $(shell date -u +%Y%m%dT%H%M%SZ)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

.PHONY: setup
setup: ## Fetch Go + Flutter dependencies
	go mod download
	cd $(APP_DIR) && flutter pub get

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

.PHONY: submodules
submodules: ## Initialize/update the vendored fork submodules
	git submodule update --init --recursive

.PHONY: build
build: submodules ## Build the photon Go binary (the serve sidecar)
	mkdir -p build
	go build -o $(PHOTON) .

.PHONY: build-swift
build-swift: ## Build the PhotoKit helper and menu bar app
	swift build -c release --package-path swift-helper
	swift build -c release --package-path menubar-app

.PHONY: build-flutter
build-flutter: build ## Build the Flutter macOS app (debug)
	cd $(APP_DIR) && flutter build macos --debug

.PHONY: build-release
build-release: build ## Build the Flutter macOS app (release)
	cd $(APP_DIR) && flutter build macos --release

.PHONY: build-linux
build-linux: build ## Build the Flutter Linux desktop app (release)
	cd $(APP_DIR) && flutter build linux --release

.PHONY: run-linux
run-linux: build ## Run the Flutter Linux desktop app (debug)
	cd $(APP_DIR) && flutter run -d linux

.PHONY: build-apk
build-apk: ## Build the Flutter Android debug APK
	cd $(APP_DIR) && JAVA_HOME=$(JAVA_HOME) flutter build apk --debug

.PHONY: run-android
run-android: ## Run the Flutter app on a connected Android device (needs adb reverse)
	cd $(APP_DIR) && JAVA_HOME=$(JAVA_HOME) flutter run -d android

.PHONY: reverse
reverse: ## Forward device tcp:8787 to a local photon serve
	@mkdir -p $(HOME)/Library/Android/sdk/platform-tools 2>/dev/null; \
	ADB=$$(command -v adb 2>/dev/null || echo $(HOME)/Library/Android/sdk/platform-tools/adb); \
	$$ADB reverse tcp:8787 tcp:8787
	@echo "photon serve must be running on 127.0.0.1:8787 (make run-serve)"

.PHONY: app-bundle
app-bundle: ## Assemble the full PhotonMigrate.app bundle (menubar migration app)
	./build-app.sh

# ---------------------------------------------------------------------------
# Test / lint
# ---------------------------------------------------------------------------

.PHONY: test
test: ## Run all tests (Go race tests + Flutter widget tests)
	go test -race $(PKGS)
	cd $(APP_DIR) && flutter test

.PHONY: vet
vet: ## Go vet + flutter analyze
	go vet $(PKGS)
	cd $(APP_DIR) && flutter analyze

.PHONY: analyze
analyze: vet ## Alias for vet+analyze

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

.PHONY: run
run: build ## Run the Flutter macOS app in debug mode
	cd $(APP_DIR) && flutter run -d macos

.PHONY: run-serve
run-serve: build ## Run photon serve on the host (for adb reverse / remote dev)
	./$(PHOTON) serve --addr 127.0.0.1:8787

.PHONY: build-all
build-all: build build-swift build-flutter build-apk build-linux ## Build every artifact

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

.PHONY: install-linux
install-linux: build-linux ## Install the Linux app into $(PREFIX) with a desktop entry
	@test ! -e '$(PREFIX)/lib/photon/versions/$(BUILD_TAG)' \
	  || { echo "error: $(PREFIX)/lib/photon/versions/$(BUILD_TAG) already exists" >&2; \
	       echo "       (two installs in the same second? pass BUILD_TAG=<tag>)" >&2; exit 1; }
	mkdir -p '$(PREFIX)/lib/photon/versions/$(BUILD_TAG)' \
	  '$(PREFIX)/bin' \
	  '$(PREFIX)/share/applications' \
	  '$(PREFIX)/share/icons/hicolor/512x512/apps'
	cp -r '$(ROOT)/app/build/linux/x64/release/bundle/.' '$(PREFIX)/lib/photon/versions/$(BUILD_TAG)/'
	cp '$(ROOT)/build/photon' '$(PREFIX)/lib/photon/versions/$(BUILD_TAG)/photon'
	chmod +x '$(PREFIX)/lib/photon/versions/$(BUILD_TAG)/photon_library' \
	  '$(PREFIX)/lib/photon/versions/$(BUILD_TAG)/photon'
	ln -sfn '$(PREFIX)/lib/photon/versions/$(BUILD_TAG)' '$(PREFIX)/lib/photon/current'
	ln -sfn '$(PREFIX)/lib/photon/current/photon' '$(PREFIX)/bin/photon'
	cp '$(ROOT)/assets/AppIcon-1024.png' \
	  '$(PREFIX)/share/icons/hicolor/512x512/apps/photon-library.png'
	printf '%s\n' \
	  '[Desktop Entry]' \
	  'Type=Application' \
	  'Name=Photon Library' \
	  'Comment=Browse your Proton Photos library' \
	  'Exec=$(PREFIX)/lib/photon/current/photon_library' \
	  'Icon=photon-library' \
	  'Terminal=false' \
	  'Categories=Graphics;' \
	  'StartupNotify=true' \
	  > '$(PREFIX)/share/applications/photon-library.desktop'
	@command -v gtk-update-icon-cache >/dev/null 2>&1 && \
	  gtk-update-icon-cache -f -t '$(PREFIX)/share/icons/hicolor' 2>/dev/null || true
	@command -v update-desktop-database >/dev/null 2>&1 && \
	  update-desktop-database '$(PREFIX)/share/applications' 2>/dev/null || true
	@echo "Installed Photon Library $(BUILD_TAG) to '$(PREFIX)' (desktop entry: photon-library)"

.PHONY: uninstall-linux
uninstall-linux: ## Remove the Linux app installed by install-linux
	# Old versioned installs are left in place by install-linux on purpose:
	# deleting one while an instance is still running from it re-creates the
	# SIGBUS crash. uninstall-linux removes the whole tree, so stop the app
	# first. To free just the versions you no longer need:
	#   rm -rf '$(PREFIX)/lib/photon/versions/' '$(PREFIX)/lib/photon/current'
	rm -rf '$(PREFIX)/lib/photon'
	rm -f '$(PREFIX)/bin/photon'
	rm -f '$(PREFIX)/share/applications/photon-library.desktop'
	rm -f '$(PREFIX)/share/icons/hicolor/512x512/apps/photon-library.png'
	@command -v gtk-update-icon-cache >/dev/null 2>&1 && \
	  gtk-update-icon-cache -f -t '$(PREFIX)/share/icons/hicolor' 2>/dev/null || true
	@command -v update-desktop-database >/dev/null 2>&1 && \
	  update-desktop-database '$(PREFIX)/share/applications' 2>/dev/null || true
	@echo "Removed Photon Library from '$(PREFIX)'"

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf build/ $(APP_DIR)/build/ $(APP_DIR)/.dart_tool/
	go clean
	swift package clean --package-path swift-helper
	swift package clean --package-path menubar-app