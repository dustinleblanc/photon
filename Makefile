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

.PHONY: build
build: ## Build the photon Go binary (the serve sidecar)
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

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf build/ $(APP_DIR)/build/ $(APP_DIR)/.dart_tool/
	go clean
	swift package clean --package-path swift-helper
	swift package clean --package-path menubar-app