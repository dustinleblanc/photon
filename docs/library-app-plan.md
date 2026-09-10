# Photon Library — App Build Plan

A cross-platform client for a **Proton Photos** library: browse on demand, organize,
hide, export/convert, and (later) detect people — without downloading the whole
library to every device.

Working name: **Photon Library**. The `photon` CLI keeps the migration commands;
this plan is for the browsing/management app.

---

## 1. Goals & non-goals

**Goals**
- Browse the Proton Photos library from macOS, Linux, Windows, iOS, Android.
- Keep originals in Proton; show **local thumbnails**, download originals **on demand**.
- Organize: albums, folders/tags, and a **hidden** state (UI-level for now).
- Export with **conversion + resize** (HEIC→JPEG/PNG/WebP, batch presets, metadata strip).
- Face/person detection (people, clusters, naming) — later.
- Share as much code as possible across platforms via a layered, interface-driven design.
- (Later) share catalog data between a user's devices.

**Non-goals (for now)**
- Non-destructive photo editing. Hand a file to an external editor instead.
- A custom sync/backend service. Proton is the storage; the catalog is local.
- True cryptographic vault for the hidden folder (see §7) — revisit later.

---

## 2. Architecture

Three layers, dependency arrows point **inward** (ports & adapters / hexagonal):

```
┌─────────────────────────────────────────────────────────────┐
│  UI  (Flutter — one codebase, all five platforms)            │
│    grid · lightbox · albums · people · export · settings     │
│    native UX primitives via Flutter plugins                  │
└───────────────────────────▲─────────────────────────────────┘
                            │ HTTP/JSON on loopback (primary)
                            │ or FFI bindings (optional)
┌───────────────────────────┴─────────────────────────────────┐
│  CORE (Go)  — platform-agnostic domain                       │
│    ProtonClient · Catalog(SQLite) · Cache · Exporter         │
│    HiddenFilter · PeopleService · SyncEngine                 │
│    defines PORTS for native-only codec/ML capabilities       │
└───────────────────────────▲─────────────────────────────────┘
                            │ implemented per OS
┌───────────────────────────┴─────────────────────────────────┐
│  ADAPTERS  (thin, per platform)                              │
│    ImageCodec · FaceEngine  (+ SecureStore if needed)        │
└─────────────────────────────────────────────────────────────┘
```

**Why this shape**
- The core is pure Go (no cgo today — `modernc.org/sqlite`), so it compiles for every
  target and is the single place business logic lives.
- **Flutter is the single UI codebase** for macOS, Linux, Windows, iOS, and Android —
  native-feeling everywhere, which was the deciding factor (open Q1).
- The **HTTP/JSON API is the seam**: the same contract is served by a sidecar process
  on desktop and by an in-process loopback server on mobile. The Flutter UI never talks
  to Proton directly.
- **Flutter plugins** own platform UX primitives (biometrics, share, pickers,
  notifications, secure storage). The Go **ports** are reserved for native codec/ML
  work (HEIC decode, face detection) that a plugin can't do where the core needs it.

### Delivery modes for the core
- **Desktop:** run `photon-serve` as a child process; Flutter calls it on loopback.
- **Mobile:** bind the core with `gomobile` and start the same HTTP server in-process
  on loopback (or call generated bindings directly as a later optimization).

### Recommended stack
- **UI:** Flutter (Dart), one app for all five platforms.
- **Core:** Go, delivered via loopback HTTP (sidecar on desktop, in-process on mobile).
- **Native primitives:** Flutter plugins — `local_auth`, `flutter_secure_storage`,
  `share_plus`, `file_picker`, `photo_manager`/`image_picker`, `flutter_local_notifications`,
  plus a `desktop_drop`/`super_drag_and_drop` for drag & drop.

### Native integration (Flutter plugins)

Flutter reaches native primitives through plugins/platform channels — materially
better than a webview, so most primitives are first-class:

| Primitive | How | Fidelity |
|---|---|---|
| Native file open/save dialogs | `file_picker` | Excellent |
| Secure storage (Keychain/Keystore) | `flutter_secure_storage` | Excellent |
| Biometrics (Touch/Face ID, Hello, BiometricPrompt) | `local_auth` | Excellent |
| Share sheet, haptics | `share_plus`, `haptic_feedback` | Excellent |
| PhotoKit / gallery access | `photo_manager` | Good |
| Notifications, badges | `flutter_local_notifications` | Good |
| Dark mode / accent color | Material 3 | Good |
| App menu / menu bar | desktop menu package | Good (macOS) |
| Navigation idioms (tab bars, back gestures, large titles) | Material/Cupertino widgets | Native |
| Drag & drop (in + out) | `desktop_drop` / `super_drag_and_drop` | Good |
| Background prefetch/upload | `workmanager`, `background_fetch` | Needs shell work |
| Widgets / Shortcuts / Spotlight | **native only** | Separate effort |
| HEIC/AVIF decode | **core adapter** (ImageIO / libheif / ffmpeg) | via core |

**Division of labor:** Flutter owns UX primitives; Go owns domain + codec/ML. The
`FaceEngine` and `ImageCodec` ports are the only places the core reaches into the OS.

---

## 3. Core ports (Go interfaces)

```go
// Auth + storage
type SecureStore interface {
    Get(key string) ([]byte, error)
    Set(key string, value []byte) error
    Delete(key string) error
}

// Image decoding/encoding is platform-specific (HEIC/RAW support differs).
type ImageCodec interface {
    Decode(r io.Reader) (image.Image, error)
    Encode(w io.Writer, img image.Image, format Format, quality int) error
    // Fit produces a scaled copy bounded by maxPx on the long edge.
    Fit(src []byte, maxPx int) ([]byte, error)
}

// Face detection + embedding; clustering/naming stays in the core.
type FaceEngine interface {
    Detect(ctx context.Context, img image.Image) ([]Face, error)
}

type Biometrics interface {
    Authenticate(reason string) (bool, error)
}

// Proton is itself an interface so the reverse-engineered client can be swapped.
type ProtonClient interface {
    ListPhotos(ctx context.Context, page string) ([]Photo, string, error)
    FetchPreview(ctx context.Context, id string, size int) ([]byte, error)
    OpenOriginal(ctx context.Context, id string) (io.ReadCloser, error)
    Upload(ctx context.Context, p UploadParams) (id string, err error)
}
```

The core's `Catalog`, `Cache`, `Exporter`, `HiddenFilter`, `PeopleService`, and
`SyncEngine` are concrete types built on these ports.

With Flutter owning platform UX, `SecureStore` and `Biometrics` move to plugins
(`flutter_secure_storage`, `local_auth`) and are dropped from the core's required
ports. The core keeps three: `ProtonClient`, `ImageCodec`, `FaceEngine`.

**FaceEngine (decided — open Q2): platform-native + fallback.** Apple Vision on
macOS/iOS, ML Kit on Android, ONNX on Linux/Windows. Caveat: each engine emits
different embeddings, so a face detected on one platform won't match the same face
on another. People may therefore be per-device unless we later pin a canonical
embedding model for cross-device matching.

---

## 4. HTTP API surface (v1)

```
# auth
POST /api/v1/auth/login            {username,password,totp,hvToken?,hvMethod?}
POST /api/v1/auth/logout
GET  /api/v1/session

# library
GET  /api/v1/assets?cursor=&album=&folder=&tag=&q=&includeHidden=false
GET  /api/v1/assets/{id}
GET  /api/v1/assets/{id}/preview?size=512        # streams JPEG preview
GET  /api/v1/assets/{id}/original                # downloads + caches, then streams
POST /api/v1/assets/{id}/hide
POST /api/v1/assets/{id}/unhide

# organization
GET  /api/v1/albums        POST /api/v1/albums
GET  /api/v1/folders       POST /api/v1/folders
GET  /api/v1/tags          POST /api/v1/tags

# people (later)
GET  /api/v1/people        GET /api/v1/people/{id}
POST /api/v1/people/{id}/name
POST /api/v1/faces/{id}/assign

# export
GET  /api/v1/export/presets
POST /api/v1/export        {assetIds, presetId | inlinePreset}
GET  /api/v1/export/{jobId}

# sync / status
GET  /api/v1/sync/status
POST /api/v1/sync/run
GET  /api/v1/health
```

**Rule:** `includeHidden` defaults to `false`; the core enforces the hidden predicate
centrally (§7). No endpoint can bypass it except the explicit reveal flow.

---

## 5. Data model (local SQLite)

```
assets(id PK, proton_link_id UNIQUE, filename, capture_time, size,
       width, height, mime, content_hash, hidden INTEGER DEFAULT 0,
       vaulted INTEGER DEFAULT 0, preview_cached INTEGER, created_at)
albums(id PK, name, hidden INTEGER DEFAULT 0, cover_asset_id)
album_assets(album_id, asset_id, PRIMARY KEY(album_id, asset_id))
folders(id PK, parent_id, name)
asset_folders(asset_id, folder_id)
tags(id PK, name)  asset_tags(asset_id, tag_id)

people(id PK, name, cover_face_id)
faces(id PK, asset_id, x, y, w, h, embedding BLOB, person_id NULL)

export_presets(id PK, name, format, max_dim, quality, strip_gps)

sync_state(key PK, value)          -- cursors, last sync, device id
```

Keying hidden/album membership by `proton_link_id` (stable) so re-syncing the catalog
from Proton never loses user state. Hidden/people state is **local to each install**
until the sync feature (§6) lands.

---

## 6. Cross-device data sharing (later)

No dedicated backend. Use Proton itself as the sync medium:

- Store a compact **catalog snapshot / op-log** as an encrypted file in Proton Drive
  "My files" (e.g. `/.photon-library/catalog.json`), written through our client.
- Merge on startup and periodically:
  - **Scope:** albums, folders, tags, hidden flags, people names + face assignments.
  - **Not** by default: thumbnails and embeddings (regenerate locally) — though
    embeddings may be synced later to avoid recompute.
- **Strategy (decided — open Q3): last-writer-wins** per record, keyed by device id +
  timestamp. Simple and predictable; concurrent edits on two devices can silently
  lose one, which is accepted for a single-user library.
- **Limitations:** eventual consistency, no conflict UI at first, size of embeddings,
  and the fact that Proton has no sync API — this is a file we manage ourselves.

---

## 7. Hidden folder

Decision: **UI-level hidden state** for now (presentation problem, not storage).

- `assets.hidden` flag; every read path goes through one `visibleAssets` predicate.
- Must apply to: grid, timeline, search, albums, folders, tags, counts, selection,
  export, **and People/faces** (a hidden photo's face must not surface).
- Hidden previews must not sit in the plaintext thumbnail cache — either skip caching
  them or cache in a locked store populated only after reveal.
- Reveal is deliberate (menu/shortcut), not a visible button; gate behind
  `Biometrics` when available.
- Modelled as a **state** so it can later become a true vault (move bytes to an
  encrypted local store) with no UI change.

Accepted risks: photos remain visible in Proton web/mobile (user won't use them);
a fresh install loses local hidden flags.

---

## 8. Platform matrix & distribution

| Capability     | macOS        | Linux            | Windows        | iOS            | Android         |
|----------------|--------------|------------------|----------------|----------------|-----------------|
| Secure store   | Keychain     | libsecret        | Cred Mgr       | Keychain       | Keystore        |
| Biometrics     | LocalAuth    | fprintd/polkit   | Windows Hello  | Face/Touch ID  | BiometricPrompt |
| Image codec    | ImageIO      | libheif/ffmpeg   | libheif/ffmpeg | ImageIO        | ImageDecoder    |
| Face engine    | Vision       | ONNX             | ONNX           | Vision         | ML Kit          |
| Background     | full         | full             | full           | limited        | WorkManager     |
| Distribution   | notarized DMG| deb/Flatpak      | installer      | sideload/Ad Hoc → App Store later | APK/F-Droid |

**Distribution (decided — open Q4): direct now, App Store later.** Desktop via
notarized DMG / Linux packages / Windows installer; Android via APK/F-Droid (trivial
on GrapheneOS); iOS via Ad Hoc/sideload or TestFlight first, with App Store as a
later best-effort goal.

**Distribution risks**
- Reverse-engineered Proton API: could break, and **App Store review may reject** it.
  Mitigation: keep Proton behind `ProtonClient`; ship direct/notarized + sideload
  first, pursue App Store as a later, lower-priority goal.
- HEIC/AVIF decode on Linux/Windows: bundle a static `ffmpeg`/`libheif` worker.

---

## 9. Phasing (one client at a time)

- **M0 — Core extraction.** Refactor `photon` internals into a reusable `core`
  module; define ports; add `photon-serve` HTTP API. No UI.
- **M1 — Desktop browse (Flutter).** Grid, lightbox, thumbnail cache, on-demand
  originals. macOS first, then Linux/Windows. Core as sidecar process.
- **M2 — Export/convert/resize.** Pure-Go codecs + bundled ffmpeg; presets; batch.
- **M3 — Albums / folders / tags + hidden.** Catalog work + central predicate.
- **M4 — Android client** (GrapheneOS, sideloaded). Core via gomobile; same Flutter UI.
- **M5 — iOS client.** Core via gomobile framework; same Flutter UI.
- **M6 — Cross-device sync** (LWW) via Proton-hosted catalog file.
- **M7 — Faces/people.** Platform-native detection + fallback (Vision/ML Kit/ONNX);
  clustering + naming. Defer cross-device embedding strategy until here.

Each milestone is independently useful and testable.

---

## 10. Repo / module layout

```
photon/                          # repo root = Go module "photon"
  main.go                        # single CLI (migrate subcommands + serve)
  core/                          # domain: ports.go, client.go, server.go
    proton/  catalog/  cache/  export/  people/  sync/   # (later)
  proton/                        # low-level Proton client (session, drive, thumbnails)
  internal/                      # migration-specific: store/, asset/
  app/                           # Flutter app (all five platforms)
    lib/  android/  ios/  macos/  linux/  windows/
  adapters/
    codec/{apple,ffmpeg}         # ImageCodec
    face/{vision,mlkit,onnx}     # FaceEngine
```

Secure storage and biometrics live in the Flutter app via plugins, so they have no
Go adapter. `core` can stay in this repo or become its own module the Flutter app
imports; the loopback HTTP seam makes the split arbitrary.

---

## 11. Decisions (resolved)

1. **UI:** Flutter (single codebase, all five platforms).
2. **Face engine:** platform-native + fallback — Vision (Apple), ML Kit (Android),
   ONNX (Linux/Windows). Cross-device embedding strategy deferred to M7.
3. **Sync:** last-writer-wins per record (device id + timestamp).
4. **Distribution:** direct now (notarized DMG / Linux packages / Windows installer /
   Android APK-F-Droid / iOS Ad Hoc or TestFlight); App Store as a later, best-effort goal.
5. **Mobile UI:** moot — Flutter gives native-feeling mobile by default.
```
