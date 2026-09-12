#!/bin/bash
# Installs the build dependencies for photon on Arch Linux.
#
# Two toolchains are required to build the desktop app:
#   - the Go core (photon CLI + `serve`, the loopback API)   -- needs Go only
#   - the Flutter "Photon Library" desktop UI                 -- needs Flutter SDK
#     + Linux desktop toolchain (clang/cmake/ninja/gtk3)
#
# The Swift/macOS components (menubar-app, swift-helper, PhotoKit) cannot
# build on Linux -- they are Apple-only and skipped here.
#
# Usage: ./setup-arch.sh
set -euo pipefail

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v pacman >/dev/null || die "pacman not found -- this script is for Arch Linux"

# Flutter's Linux desktop entry point (camera app) needs clang, cmake, ninja,
# pkg-config and GTK3. flutter_secure_storage needs libsecret at link time.
# base-devel/git/unzip are required to build AUR packages (Flutter).
say "Installing base toolchain"
sudo pacman -S --needed --noconfirm \
  base-devel \
  git \
  unzip \
  clang \
  cmake \
  ninja \
  pkgconf \
  gtk3 \
  libsecret

# The Go core needs Go >= 1.27.1 (go.mod). If the machine already has a
# newer/equal Go on PATH (e.g. via mise, as here) leave it alone rather than
# shadowing it with pacman's copy.
go_ok() {
  command -v go >/dev/null || return 1
  local v
  v="$(go version | awk '{print $3}')" # e.g. "go1.27.1"
  v="${v#go}"                          # "1.27.1"
  [ "$(printf '%s\n' "$v" "1.27.1" | sort -V | head -n1)" = "1.27.1" ]
}
say "Checking Go version"
if go_ok; then
  say "Go $(go version | awk '{print $3}') -- good"
else
  if command -v go >/dev/null; then
    say "Go on PATH is too old; installing the distro package instead"
  fi
  sudo pacman -S --needed --noconfirm go
  go_ok || die "Go on PATH is still older than 1.27.1 -- install Go 1.27.1+ (go.mod requires it)"
fi

# Flutter SDK. There is no Flutter in the official repos; the monolithic
# `flutter-bin` AUR package ships the SDK (with the Linux desktop target) plus
# Dart. Prefer an existing AUR helper, fall back to a manual makepkg build.
install_flutter() {
  if command -v yay >/dev/null; then
    yay -S --needed --noconfirm flutter-bin
  elif command -v paru >/dev/null; then
    paru -S --needed --noconfirm flutter-bin
  else
    say "No AUR helper found; building flutter-bin with makepkg"
    local tmp; tmp="$(mktemp -d)"
    git clone https://aur.archlinux.org/flutter-bin.git "$tmp/flutter-bin"
    (cd "$tmp/flutter-bin" && makepkg -si --noconfirm)
    rm -rf "$tmp"
  fi
}

say "Checking for Flutter SDK"
if command -v flutter >/dev/null || [ -x /opt/flutter/bin/flutter ]; then
  say "Flutter already installed"
else
  install_flutter
fi

FLUTTER=flutter
command -v flutter >/dev/null || FLUTTER=/opt/flutter/bin/flutter
"$FLUTTER" config --enable-linux-desktop >/dev/null 2>&1 || true

say "Verifying Flutter"
"$FLUTTER" --version
command -v flutter >/dev/null \
  || say "Log out/in (or open a new shell) for /opt/flutter/bin to join PATH"

say
say "Dependencies installed."
say "Next steps:"
say "  1. cd app && flutter pub get"
say "  2. flutter create --platforms=linux .   # the Linux desktop runner isn't committed yet"
say "  3. cd .. && go run . serve --addr 127.0.0.1:8787"
say "  4. cd app && flutter run -d linux"