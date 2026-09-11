# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.0] - 2026-09-11

### Added

- macOS desktop support for the ML features: the scan button, People filter
  bar, and per-photo People panel now work on the Mac (the face models run
  through the plugin's native-assets path, producing the same 192-dim
  embeddings as Android).
- People browser as a full screen: one photo tile per person (their largest
  detected face, cropped with padding for context), type-ahead search across
  names and aliases in the app bar, per-tile menu for editing names/aliases,
  contact linking (Android), and deletion, plus combine-to-one-person mode.
- Unnamed-people worklist page: a grid of face captures with quick naming
  fields (type-ahead over existing people) and an ignore action. Naming or
  ignoring a face drops it off the page immediately; ignored faces stop
  counting as unnamed and can still be named later from a photo's panel.
- Filtering by a person now shows their name as the app bar title with a
  back button to return to the unfiltered gallery.
- Diagnostics tools for face detection and index contents on the host
  (`app/tool/`).

### Fixed

- The detection index now opens on macOS: debug builds lack the keychain
  entitlements flutter_secure_storage needs (errSecMissingEntitlement
  -34018), so identities were silently never persisted. The index key now
  falls back to a 0600 file in the app support directory on non-Android
  platforms.
- Face grids recycled tile state by position, so a tile that dropped off
  kept its stale thumbnail; grids now use stable keys.
- Tiny faces (e.g. a distant child in the frame corner) produced unusable
  thumbnail crops; face crops are now padded 35% on every side.

## [0.5.0] - 2026-09-11

### Added

- People can now be linked to a device contact (Android): a "Link a
  contact…" button in the photo People panel and in the gallery People sheet
  opens a searchable contact picker, and the chosen person's name and photo
  are used for the identity. Linked people show their contact picture and
  display name in the People sheet, and the link can be unlinked again.
  READ_CONTACTS is requested at first use.

### Changed

- Face-match threshold loosened from 0.6 to 0.5 so a person is picked up
  across more varied angles and lighting (the scanner's guidance rates 0.5 as
  "probably the same person").

## [0.4.0] - 2026-09-11

### Added

- On-device machine learning (Android, fully offline, encrypted at rest):
  - "Scan library" batch job runs EfficientDet-Lite2 object detection and
    MobileFaceNet face detection + 192-dim embeddings per photo, right on the
    phone, and stores results in an AES-256-encrypted Hive index whose key
    lives in the platform secure storage. Nothing ever leaves the device.
  - Gallery filters: People / Pets / Objects chips over the live detection
    index, with an "unnamed people" bucket.
  - Person tagging from a photo's People sheet: name a detected face and the
    index backfills the name across every already-scanned photo that matches
    (matching uses the stored embeddings, no re-inference needed).
  - People can go by multiple names: identities support aliases, typing a name
    already belonging to someone reuses that identity, and known people can be
    combined into one person with the sample-weighted centroid kept.
  - Correct-mismatch flow: a face auto-matched to the wrong person (or seen as
    "new") can be re-tagged onto any existing person from the People panel.

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
