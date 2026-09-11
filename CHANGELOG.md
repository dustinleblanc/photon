# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-09-11

### Added

- Android app: deeply integrated with the platform — share sheet, "save to
  gallery" (MediaStore), and a DocumentsProvider that exposes the library to
  system file pickers (e.g. the Files app) with working search.
- "Set as wallpaper" from the lightbox: saves the photo then opens the system
  wallpaper cropper directly via `ACTION_CROP_AND_SET_WALLPAPER`, so the
  contact-photo picker can no longer steal the intent.
- Lightbox actions now live in a Material 3 bottom sheet (Set as wallpaper,
  Save to gallery, Share, Download original) instead of a stacked button bar,
  and appear as soon as the preview loads (the original is fetched lazily).
- Request logging on the loopback `serve` API.

### Fixed

- Original downloads failed on Android with "connection closed while receiving
  data": serve advertised Proton's block-padded encrypted size as
  Content-Length, which is larger than the actual decrypted bytes. It now
  streams chunked, and the client retries transient tunnel drops.
- Photos set as wallpaper appeared rotated 90° because the cropper ignores
  EXIF orientation; the save path now bakes the EXIF rotation into upright
  JPEG pixels before writing to MediaStore.

## [0.2.0] - 2026-09-10

### Added

- `serve` command: a loopback HTTP API for the Photon Library UI (auth,
  paginated asset listing, on-demand original download, and photo previews).
- Encrypted thumbnail download — previews are fetched from Proton and
  decrypted client-side (full decrypt-and-verify, matching Proton's E2E model).
- `retry-failed` command to requeue failed assets, plus a "Retry Failed" button
  in the menu bar app.
- App icon and a menu bar donut progress ring with a camera glyph.

### Changed

- Renamed the project from `photon-migrate` to **photon**: a single `photon`
  CLI with subcommands, with shared (non-migration) code hoisted into `core/`
  and `proton/` packages.

## [0.1.2] - 2026-09-08

### Fixed

- Released app bundles now ship every executable with the execute bit set
  (the lipo merge dropped it), and the merge job fails loudly if any binary
  is not executable.

## [0.1.1] - 2026-09-08

### Fixed

- Restored the execute bit on the universal binaries after the lipo merge.

## [0.1.0] - 2026-09-08

### Added

- Initial public release: the migration CLI, menu bar app, `photos-helper`,
  release pipeline, and vendored dependency forks.
