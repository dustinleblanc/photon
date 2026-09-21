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
ADB       ?= $(shell command -v adb 2>/dev/null || echo $(HOME)/Library/Android/sdk/platform-tools/adb)
ANDROID_APP_ID := com.dustinleblanc.photon.photon_library

# Target selection for adb install/shell. Prefers ANDROID_SERIAL, otherwise the
# first connected device. The same phone often shows up twice (a USB/tcp entry
# plus an mDNS TLS entry), and a bare `adb install` then fails with "more than
# one device/emulator".
ADB_SERIAL ?= $(shell $(ADB) devices | awk '$$2=="device" {print $$1; exit}')
ADB_TARGET = $(if $(ADB_SERIAL),-s $(ADB_SERIAL))
PKGS      := ./...
ROOT      := $(CURDIR)
JAVA_HOME ?= /opt/homebrew/opt/openjdk@17

# Where install-linux puts the app. Defaults to a user-local prefix so the
# install needs no root; override for a system-wide install, e.g.
# `sudo make install-linux PREFIX=/usr/local`.
PREFIX    ?= $(HOME)/.local

# Where install-mac puts the app bundle and CLI symlink. The app goes into
# the user's Applications folder (no admin needed); the CLI goes into
# MAC_PREFIX/bin (default ~/.local/bin, same convention as PREFIX).
MAC_APPS   ?= $(HOME)/Applications
MAC_PREFIX ?= $(PREFIX)

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

.PHONY: build-android-embed
build-android-embed: ## Build photon for Android arm64 into the APK's jniLibs
	@NDK_CLANG="$$(ls -d $(HOME)/Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang 2>/dev/null | head -1)"; \
	if [ -z "$$NDK_CLANG" ]; then echo "Android NDK not found (needed for cgo DNS resolution)"; exit 1; fi; \
	mkdir -p app/android/app/src/main/jniLibs/arm64-v8a; \
	CGO_ENABLED=1 GOOS=android GOARCH=arm64 CC="$$NDK_CLANG" \
		go build -trimpath -ldflags="-s -w" \
		-o app/android/app/src/main/jniLibs/arm64-v8a/libphotonserve.so .

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
build-apk: build-android-embed ## Build the Flutter Android debug APK (embeds photon serve)
	cd $(APP_DIR) && JAVA_HOME=$(JAVA_HOME) flutter build apk --debug

.PHONY: dev-mac
dev-mac: build ## Run the macOS app with hot reload (r=reload, R=restart, q=quit)
	cd $(APP_DIR) && JAVA_HOME=$(JAVA_HOME) flutter run -d macos

.PHONY: dev-android
dev-android: android-wifi-connect ## Run on the phone over Wi-Fi with hot reload (r/R/q)
	cd $(APP_DIR) && JAVA_HOME=$(JAVA_HOME) flutter run -d "$(ADB_SERIAL)"

.PHONY: run-android
run-android: android-wifi-connect ## Alias for dev-android
	cd $(APP_DIR) && JAVA_HOME=$(JAVA_HOME) flutter run -d "$(ADB_SERIAL)"

.PHONY: android-wifi-connect
android-wifi-connect: ## Connect to the phone over Wi-Fi (auto-discovers it on the LAN)
	@SVC="$(HOST)"; \
	if [ -z "$$SVC" ]; then \
	  SVC=$$($(ADB) mdns services 2>/dev/null | awk '/_adb-tls-connect\._tcp/ {print $$3; exit}'); \
	fi; \
	if [ -z "$$SVC" ]; then \
	  echo "No wireless Android device found on the network."; \
	  echo "  1. Phone: Settings > System > Developer options > Wireless debugging > ON"; \
	  echo "  2. Open 'Wireless debugging' and keep that screen on (it shows the address)"; \
	  echo "  3. Re-run 'make android-wifi-connect'"; \
	  echo "     or pass it: make android-wifi-connect HOST=192.168.1.75:33215"; \
	  exit 1; \
	fi; \
	$(ADB) disconnect "$$SVC" >/dev/null 2>&1 || true; \
	$(ADB) connect "$$SVC"; \
	$(ADB) devices -l | grep -q . || true

.PHONY: android-wifi-pair
android-wifi-pair: ## First-time Wi-Fi pairing: make android-wifi-pair HOST=ip:port CODE=123456
	@test -n "$(HOST)" -a -n "$(CODE)" || { \
	  echo "usage: make android-wifi-pair HOST=<ip:port> CODE=<6-digit code>"; \
	  echo "Both are on the phone under Wireless debugging > 'Pair device with pairing code'."; \
	  echo "(The pairing port differs from the connect port; pair once, then use android-wifi-connect.)"; \
	  exit 1; }; \
	$(ADB) pair "$(HOST)" "$(CODE)"

.PHONY: android-wifi-disconnect
android-wifi-disconnect: ## Drop the Wi-Fi adb connection
	@$(ADB) devices | awk '/:.*device$$/ {print $$1}' | xargs -n1 $(ADB) disconnect 2>/dev/null || true

.PHONY: apk-install
apk-install: ## Install the built debug APK on the connected phone, then relaunch it
	$(ADB) $(ADB_TARGET) install -r $(APP_DIR)/build/app/outputs/flutter-apk/app-debug.apk
	-@$(ADB) $(ADB_TARGET) shell am force-stop $(ANDROID_APP_ID)
	@$(ADB) $(ADB_TARGET) shell am start -n $(ANDROID_APP_ID)/.MainActivity

.PHONY: apk-wifi
apk-wifi: android-wifi-connect build-apk ## Build the APK and push it to the phone over Wi-Fi
	$(MAKE) apk-install
	@echo "Pushed to the phone over Wi-Fi."

.PHONY: reverse
reverse: ## (Legacy) Forward device tcp:8787 to a host photon serve; not needed with the embedded server
	@echo "Not needed any more: the Android app runs photon serve on-device."

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

.PHONY: install-mac
install-mac: build-release ## Install the macOS app into ~/Applications (MAC_APPS) with embedded sidecar
	@test ! -e '$(MAC_APPS)/Photon Library.app' \
	  || { echo "error: $(MAC_APPS)/Photon Library.app already exists" >&2; \
	       echo "       (remove it first: make uninstall-mac)" >&2; exit 1; }
	@test -d '$(ROOT)/app/build/macos/Build/Products/Release/Photon Library.app' \
	  || { echo "error: release build output missing" >&2; exit 1; }
	mkdir -p '$(MAC_APPS)' '$(MAC_PREFIX)/bin'
	cp -R '$(ROOT)/app/build/macos/Build/Products/Release/Photon Library.app' \
	  '$(MAC_APPS)/Photon Library.app'
	cp '$(ROOT)/build/photon' \
	  '$(MAC_APPS)/Photon Library.app/Contents/Resources/photon'
	chmod +x '$(MAC_APPS)/Photon Library.app/Contents/Resources/photon'
	# Ad-hoc signing: the app is unsigned from flutter build; without a
	# signature macOS may refuse to run it (or kill it after quarantining).
	codesign --force --deep --sign - '$(MAC_APPS)/Photon Library.app' \
	  2>/dev/null || true
	ln -sfn '$(MAC_APPS)/Photon Library.app/Contents/Resources/photon' \
	  '$(MAC_PREFIX)/bin/photon'
	@echo "Installed Photon Library to '$(MAC_APPS)/Photon Library.app'"
	@echo "CLI: $(MAC_PREFIX)/bin/photon (serve sidecar is embedded in the app)"

.PHONY: uninstall-mac
uninstall-mac: ## Remove the macOS app installed by install-mac (~/Applications)
	# Stop a running instance first: deleting the bundle under a live app
	# breaks its next launch (and the running binary's Resources path).
	@osascript -e 'quit app "Photon Library"' 2>/dev/null || true
	sleep 1
	rm -rf '$(MAC_APPS)/Photon Library.app'
	rm -f '$(MAC_PREFIX)/bin/photon'
	@echo "Removed Photon Library from '$(MAC_APPS)'"

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