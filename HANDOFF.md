# photon-migrate — session handoff

Written 2026-09-08 for whoever (human or LLM) picks this up next. Read this
before touching code — several of the decisions here look wrong until you
know what broke without them.

## What this is

A tool to migrate a full iCloud/Google Photos library into **Proton
Photos** (not just Proton Drive — the actual Photos timeline, with
thumbnails, indistinguishable from something uploaded by Proton's own
apps). Built because no such tool exists: Proton's API for this is
undocumented, and we reverse-engineered it from Proton's own open-sourced
iOS/macOS/Web client source and their official (early, incomplete) Drive
SDK.

The user now wants to **share this with other people** who want to do the
same migration. That reframes several choices below — things that were
fine for one person's use are not fine to hand to a stranger.

## Live state right now

```
pending=6546 uploaded=3323 skipped_duplicate=0 failed=5
```

No upload process is currently running (check with
`ps aux | grep photon-migrate` before assuming otherwise — it may have
been restarted since this was written). Total library: 9,874 assets.

**Not a git repository.** `~/projects/photon-migrate` has no `.git`. This
is the single most important gap — weeks of debugging live only as
uncommitted files on one machine. Strongly recommend `git init` +
first commit before any further work, and before ever considering deleting
anything.

## Architecture

Three components, one SQLite database as the shared state:

```
menubar-app/    SwiftUI menu bar app — the GUI, owns credentials/Keychain
swift-helper/   CLI tool using PhotoKit — reads the local Photos library
go-uploader/    CLI tool — Proton auth, encryption, upload, all state
```

They talk by **subprocess + JSON on stdout, one line of progress per
stderr line**. Go spawns Swift (for photo export/thumbnails), and the
Swift app spawns Go (for everything Proton-related). No shared memory, no
sockets — deliberately simple, and it works.

Database: `~/Library/Application Support/photon-migrate/photon-migrate.db`
(SQLite, WAL mode, `0600` permissions — see `internal/store/store.go`).
Holds the asset queue and status only. **Credentials do NOT live here** —
see Auth section.

### Why subprocesses instead of one binary

This came up explicitly: "why not rewrite it all in Swift, or link Go into
the app as a C archive?" Answer, confirmed by reading Proton's own source:
**Proton's own Swift apps don't implement the crypto in Swift either** —
they link a compiled Go OpenPGP library (`GoLibsCryptoGo.xcframework`) and
bind to it from Swift. There is no native-Swift path here that Proton
themselves use. Rewriting to "pure Swift" would mean reimplementing crypto
Proton also just calls into Go for. Not worth it. The subprocess boundary
is fine; packaging (see below) was the real problem, and that's solved.

## Auth: one session, lives in the Keychain, never on disk

This went through several wrong designs this session before landing right.
**If you're about to change auth, read this whole section first.**

- There used to be **two separate Proton login stacks** (one for
  status/reconcile, one for uploads, on incompatible client libraries).
  This caused double-captcha prompts and 400+ lines of duplication.
  **Deleted** — `internal/proton/` no longer exists. Everything now goes
  through `internal/upload` (despite the package name, it's the only auth
  stack).
- Session shape (`upload.Session` in Go / `ProtonSession` in Swift):
  `{uid, accessToken, refreshToken, saltedKeyPass}`. **`saltedKeyPass` is
  required** — it's what unlocks the user's PGP keyring on resume. An
  older/incomplete session missing it produces the deeply unhelpful
  `gopenpgp: private key checksum failure` several layers down. Both sides
  now validate completeness before trusting a stored session
  (`upload.Resume` in Go, `PhotonRunner.storedSession()` in Swift) and fail
  with a clear "sign in again" message instead.
- **Credentials live only in macOS Keychain**, written by the Swift app.
  Go is stateless about auth — it never touches Keychain, never writes
  credentials to the database. It takes a session in via
  `PROTON_UPLOAD_SESSION_JSON` (env, only in-process, not on disk) and, if
  the caller wants the (possibly rotated — access tokens expire and
  refresh mid-run) session back, writes it to a path the caller supplies
  via **`--session-out <path>`**.
- **`--session-out` is opt-in and this matters a lot.** Earlier this
  session, the Go side printed the rotated session to stderr
  unconditionally. Fine when only the app silently consumed it — a real
  problem for a shared tool, since anyone running the CLI directly gets
  live credentials (including `saltedKeyPass`, sufficient on its own to
  re-auth as the user) dumped into terminal scrollback and shell history
  on nearly every invocation (access tokens are short-lived; a refresh
  happens almost every run). Fixed: no flag → no output, ever. The Swift
  app creates a private temp file per call
  (`PhotonRunner.makeSessionOutPath()`), passes it, reads it back after
  the process exits, deletes it either way. See `writeUploadSession()` in
  `main.go` and `consumeSessionOutFile()` in `PhotonRunner.swift`.
- `AppLog.swift` redacts `accessToken`/`refreshToken`/`saltedKeyPass`
  before writing anything to `~/Library/Logs/PhotonMigrate/photon-migrate.log`.
  **`saltedKeyPass` was missing from that redaction list for a while this
  session** — meaning early in this session, sign-ins logged the key
  passphrase in plaintext to that log file. It's fixed now, but the old
  log content isn't retroactively cleaned. If you're auditing for leaked
  secrets, check that file's history / consider it already compromised for
  whatever account was used during development, or just delete it.
- 1Password integration was **removed entirely** (it was a bad fit for
  something meant to be shared — assumed `op` installed/authed/an item
  named a specific way). Sign-in is just three fields now; a properly
  signed build gets Keychain/AutoFill for free.
- Human verification (captcha): Proton's fraud detection can demand a
  captcha on login. This is handled for real — `HumanVerificationView.swift`
  renders Proton's actual hosted `verify.proton.me` widget in a `WKWebView`
  (not a bypass), extracts the solved token via the `postMessage` protocol
  Proton's own iOS app uses, and retries the auth request with the right
  headers. This was reverse-engineered from Proton's open-sourced
  `protoncore_ios` — see `Client+Duplicates.swift`/`HumanCheckHelper` etc.
  in that repo if you need to re-derive it. **One login now, one possible
  captcha**, not two.

## The Proton Photos protocol (the actual reverse-engineering)

None of this is documented anywhere by Proton. All of it was derived by
reading their open-sourced client repos (`ios-drive`, `mac-drive`,
`protoncore_ios`, and their early official `sdk` repo — all on GitHub
under `ProtonDriveApps`/`ProtonMail`). If you need to re-verify any of
this, that's where to look.

**Every one of these was a real bug found by watching actual uploads
fail.** Do not simplify without understanding why it's there.

1. **Uploading into Photos is structurally the same as uploading into
   regular Drive** — same `/shares/{id}/files` create endpoint — just
   targeted at the account's Photos-type share/volume instead of the main
   Drive share. `ShareType` value `4` = Photos; not in any public enum,
   confirmed from `ListSharesEndpoint.swift`.

2. **Block verification token** (`third_party/go-proton-api/block_verify.go`).
   The `/drive/blocks` endpoint rejects uploads with a generic, misleading
   "outdated app" error unless each block includes a `Verifier.Token`.
   Formula, confirmed from Proton's official SDK
   (`blockVerifier.ts`/`cryptoService.ts`):
   `token[i] = verificationCode[i] XOR encryptedBlockData[i]` for the first
   32 bytes. **`verificationCode` must come from the server** — via
   `GET /drive/v2/volumes/{v}/links/{l}/revisions/{r}/verification` — NOT
   derived locally from the content key packet (that only applies to a
   different, unused "small file" upload path). Getting this wrong
   produces `Code=200501` ("verification failed"), misleadingly worded as
   an app-version problem.

3. **Manifest hash ordering.** The final commit's manifest signature
   covers thumbnail hashes (sorted by type) **then** content block hashes,
   in that order. Wrong order = signature doesn't verify, opaque failure.
   Confirmed from `smallFileUploader.ts`.

4. **The plaintext `Photo` commit field.** Photos-share commits need a
   **plaintext** (not inside the encrypted `XAttr`) `Photo: {CaptureTime,
   ContentHash}` object on the commit request — the server can't decrypt
   `XAttr` to check anything, so it needs this unencrypted. Missing it
   produces `Code=2511`, "Cannot commit Revision in Photo Share without
   Photo attributes". `ContentHash` formula:
   `lower_hex(hmacSha256(parent_folder_hash_key, lower_hex(sha1(plaintext_content))))`.
   See `CommitRevisionPhotoDto` in Proton's SDK's generated API types for
   the schema.

5. **Thumbnails** (`third_party/proton-api-bridge/file_upload.go`,
   `swift-helper/.../main.swift` `writeThumbnail`/`videoThumbnail`).
   Two sizes, exact limits from Proton's own `PDCore/Constants.swift`:
   Type 1 "default" ≤512×512/60KB, Type 2 "photo" ≤1920×1920/1MB. **Can
   only be attached during the block-upload phase** — the thumbnail
   endpoint is GET-only, there is no API to add one after commit. A photo
   uploaded without one has no preview, permanently, unless re-uploaded as
   a new revision (`backfill-thumbnails` command does exactly this).
   Videos get a frame via `AVAssetImageGenerator` at 1s (falling back to
   0s for very short clips) rather than `PHImageManager.requestImage`,
   which is display-oriented and silently returns nil for many assets —
   use `requestImageDataAndOrientation` + `CGImageSource` instead.

6. **Dedup must check content, not just filename.** Camera filenames
   collide constantly (`DSC01107.JPG`, `image000000.jpg` — literally
   dozens of instances in this real library). Matching on filename hash
   alone (an earlier bug this session) **silently drops different photos
   that happen to share a name** — far worse than a duplicate upload.
   Fixed: on a name collision, hash the actual content and compare against
   Proton's stored `ContentHash` before deciding it's really a duplicate.
   See `resolveNameCollision` in `main.go`.

7. **Filename collision resolution must be batched, not probed one at a
   time.** With a name already at `(97)`, probing sequentially costs 96+
   API round trips for one photo. Proton's duplicates endpoint takes a
   list of name hashes — batch 20 candidates per request instead. See
   `FindAvailableName` in `third_party/proton-api-bridge/photos_duplicate_check.go`.

8. **App version string.** Proton gates some endpoints on a minimum client
   version. Currently `macos-drive@3.0.2` (was current as of Aug 2026 per
   Proton's release notes) — **this will need bumping again** as Proton
   ships updates. If uploads start failing with "outdated app"-shaped
   errors again, check Proton's current release notes for the real
   version number before assuming it's a code bug. Set in
   `internal/upload/upload.go` (`appVersion` const).

## Vendored, patched dependencies — read before `go get -u`

`go-uploader/third_party/` contains **modified forks**, not pristine
vendoring. Both are **MIT licensed** (`henrybear327/go-proton-api`,
`henrybear327/Proton-API-Bridge`) — this corrects an earlier assumption
in this session that GPL might apply; the user said GPLv3 would be fine
regardless, so it's not a blocker either way, just worth being accurate
about. Separately: the *algorithms* in the "Protocol" section above
(verification token, manifest ordering, content hash formula) were learned
by reading Proton's own **GPLv3** client source, even though no code was
copied — a reasonable but not bulletproof position if this goes public.
Worth a real look, not just an assumption, before wide distribution.

A `go get -u` will silently discard every patch below and break the build
in confusing ways. **There is no `PATCHES.md` yet** — writing one is a
priority TODO (see below). Until then, here's the list:

`go-proton-api` additions/edits:
- `photos.go`, `photos_duplicates.go`, `block_verification_data.go`,
  `block_verify.go` — new files, Photos API support upstream lacks
  entirely (share type, listing, duplicates check, verification data)
- `block.go`, `block_types.go` — added `Verifier`/thumbnail fields to the
  block upload request
- `link_types.go` — added `XAttr` field for cross-version compatibility
- `link_file_types.go` — added `Camera` XAttr struct, `CommitRevisionPhoto`
  plaintext field, `ComputePhotoContentHash`
- `address.go` — trivial fix, `slices.SortFunc` signature drift

`Proton-API-Bridge` additions/edits:
- `photos_bootstrap.go` — `NewProtonDriveForPhotos` (bootstraps against
  the Photos share instead of main Drive share), `ListPhotos`
- `photos_duplicate_check.go` — content-hash-aware dedup,
  `FindAvailableName` (batched collision resolution)
- `file_upload.go` — thumbnail encryption/upload, manifest ordering fix,
  `Photo` plaintext commit field, `ReplaceExistingDraft` wiring
- `common/config.go`, `common/user.go` — HV (captcha) token support,
  `ReplaceExistingDraft = true` by default (needed for retries to work —
  without it, a retry after a partial upload hits "draft already exists"
  and fails permanently)

## Resilience (added this session — real data-loss bugs found live)

While running against ~9,874 real assets overnight, two things silently
lost photos before these fixes existed:

- **iCloud download stalls forever with no timeout.**
  `PHAssetResourceManager.requestData` has no timeout parameter; a video
  that needs downloading from iCloud can hang indefinitely at 0% CPU,
  blocking the entire batch (observed: 30 minutes on one video). Fixed
  with a **stall watchdog** (`resilience.go`) — kills the export if no
  bytes arrive for 5 minutes (`PHOTON_EXPORT_STALL_TIMEOUT`), not a fixed
  deadline (large videos legitimately take a while; what matters is
  whether bytes are still arriving).
- **Transient errors (502s from Proton's storage backend) were recorded
  as permanent failures** and silently dropped from the migration — failed
  rows are never retried. Fixed: `isTransient()` classifies 5xx/network/
  timeout errors, `withRetry()` retries those with backoff
  (5s/15s/45s) before giving up. Tested under `-race`; see
  `resilience_test.go`.
- **An asset interrupted by Stop/quit was being marked failed** (same
  silent-drop problem — cancellation isn't a real failure). Fixed:
  `ctx.Err() != nil` is checked before recording a failure.
- **Concurrent uploads need a name reservation** (`queue.go`,
  `nameReserver`) — without it, two workers could both find the same
  free filename before either creates it, and Proton's behavior on a
  name conflict is to create a **new revision on the existing file**
  rather than reject it, silently burying one photo behind another.
  Tested under `-race` (`queue_test.go`).
- **Advisory lock** (`internal/store/store.go`, `AcquireLock`/`ReleaseLock`)
  stops two `upload-batch`/`backfill-thumbnails` processes running at
  once. Takes over a lock whose PID is gone (crash recovery) — but be
  careful with the "is the PID alive" check: **signalling a PID you don't
  own returns `EPERM`, which must NOT be read as "dead"** (this was a real
  bug caught mid-session — `syscall.EPERM` counts as alive in
  `processAlive()`).
- **Clean shutdown**: `SIGTERM`/`SIGINT` stop between files, not mid-
  revision (`signal.NotifyContext`). `--exit-with-parent` makes the Go
  process watch its parent PID and stop if it disappears (covers a GUI
  force-quit, where no cleanup handler runs — macOS does not kill
  children when a parent exits).

Currently 3 concurrent workers (`PHOTON_UPLOAD_WORKERS`, default 3).

## Packaging

`build-app.sh` (repo root) assembles a real `.app`:

```
PhotonMigrate.app/Contents/
  MacOS/PhotonMigrate       (the Swift menu bar binary)
  Resources/photon-migrate  (Go binary)
  Resources/photos-helper   (Swift PhotoKit helper)
  Info.plist                (LSUIElement + NSPhotoLibraryUsageDescription)
```

Both helper binaries resolve themselves relative to where they're running
(bundle Resources → dev checkout → env override), so **no hardcoded
paths remain**. Ad-hoc signed only — runs on the machine that built it,
Gatekeeper will block it on anyone else's Mac. Real distribution needs a
Developer ID + notarization.

## Outstanding TODOs, roughly prioritized

1. **`git init` + commit.** Nothing is version controlled. Do this before
   anything else.
2. **`third_party/PATCHES.md`** — the vendored-changes list above needs to
   live in the repo, not just this handoff, or the next `go get -u`
   silently reverts weeks of debugging.
3. **README** — nothing explains setup to a new user: Photos permission,
   sign-in/captcha flow, what `upload-batch` vs `backfill-thumbnails` do.
4. **LICENSE** — user said GPLv3 is fine; hasn't been added yet.
5. **Developer ID signing + notarization** — required before anyone else
   can run the built app without a Gatekeeper fight.
6. **The captcha app-version string will go stale.** No monitoring for
   this; it'll manifest as mysterious upload failures someday.
7. Two known permanently-failed assets in the current library (no
   PhotoKit resources at all, likely corrupt library entries) — not worth
   chasing, just documenting so they're not mistaken for a bug.

## How to build / run everything

```bash
# Go binary + tests
cd go-uploader && go build -o photon-migrate . && go vet ./... && go test -race ./...

# Swift helper
cd swift-helper && swift build

# Menu bar app (dev)
cd menubar-app && swift run

# Full packaged app
./build-app.sh
open build/PhotonMigrate.app
```

CLI usage directly (useful for debugging without the app):

```bash
cd go-uploader
export PROTON_USERNAME=... PROTON_PASSWORD=... PROTON_2FA=...
./photon-migrate upload-batch --limit 10          # small test batch
./photon-migrate backfill-thumbnails --limit 10   # fix missing previews
./photon-migrate status --json
./photon-migrate reconcile                        # match against Proton's own backup
```

Env vars: `PHOTON_MIGRATE_DB`, `PHOTOS_HELPER_PATH`, `PROTON_USERNAME`,
`PROTON_PASSWORD`, `PROTON_HV_TOKEN`/`PROTON_HV_METHOD`,
`PROTON_UPLOAD_SESSION_JSON`, `PHOTON_UPLOAD_WORKERS`,
`PHOTON_EXPORT_STALL_TIMEOUT`, `PHOTON_THUMBNAIL_TIMEOUT`.

## Testing notes

Go tests (`resilience_test.go`, `queue_test.go`) cover the parts that fail
*silently* when wrong — retry classification, name reservation
concurrency — and are run under `-race`. Nothing else has automated
coverage; the Proton protocol details above were validated by running
against the user's real, live library (9,874 real assets), not by unit
tests. If you change any of the protocol-level code, the only real
validation is running a small `--limit N` batch against a live account and
checking the photo actually appears correctly in Proton Photos (gallery,
not just Drive file browser) with its thumbnail.
