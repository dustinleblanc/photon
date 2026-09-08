# photon-migrate

Migrate your iCloud or Google Photos library into **Proton Photos** — the
actual Photos timeline, with thumbnails, indistinguishable from something
uploaded by Proton's own apps.

Proton's Photos API is undocumented. This tool was built by reverse-engineering
Proton's open-sourced iOS/macOS/Web client source and their official Drive SDK.

## Requirements

- macOS 13+ (Ventura or later)
- Photos library access (the app will prompt on first run)
- A Proton account with Drive/Photos enabled
- For building from source: Go 1.27+, Swift 5.9+

## Quick start (built app)

1. Build the app:

```bash
./build-app.sh
```

2. Open the built app:

```bash
open build/PhotonMigrate.app
```

3. Sign in with your Proton credentials. If Proton's fraud detection triggers,
   a captcha widget will appear — solve it and sign in again.

4. The app will scan your Photos library and begin uploading.

## Building from source

```bash
# Go uploader + tests
cd go-uploader && go build -o photon-migrate . && go vet ./... && go test -race ./...

# Swift PhotoKit helper
cd swift-helper && swift build

# Menu bar app (dev mode)
cd menubar-app && swift run

# Full packaged app
./build-app.sh
```

## CLI usage

The Go binary can be used directly without the GUI — useful for debugging
and headless/automated workflows.

```bash
cd go-uploader

# Sign in (stores session in the DB)
export PROTON_USERNAME=... PROTON_PASSWORD=... PROTON_2FA=...
./photon-migrate upload-login

# Check status
./photon-migrate status --json

# Upload a small test batch
./photon-migrate upload-batch --limit 10

# Re-upload missing thumbnails
./photon-migrate backfill-thumbnails --limit 10

# Match pending assets against what's already on Proton
./photon-migrate reconcile
```

### Environment variables

| Variable | Purpose |
|---|---|
| `PROTON_USERNAME` | Proton account email |
| `PROTON_PASSWORD` | Proton account password |
| `PROTON_2FA` | TOTP code from your authenticator |
| `PROTON_HV_TOKEN` | Human verification token (from captcha) |
| `PROTON_HV_METHOD` | Human verification method |
| `PROTON_UPLOAD_SESSION_JSON` | Pre-authenticated session JSON (overrides username/password) |
| `PHOTOS_HELPER_PATH` | Override the `photos-helper` binary location |
| `PHOTON_MIGRATE_DB` | Override the database path |
| `PHOTON_UPLOAD_WORKERS` | Number of concurrent uploads (default: 3) |
| `PHOTON_EXPORT_STALL_TIMEOUT` | Stall detection timeout (default: 5m) |

### Options

| Flag | Commands | Purpose |
|---|---|---|
| `--limit N` | `upload-batch`, `backfill-thumbnails` | Process at most N assets |
| `--json` | `status`, `plan`, `reconcile` | Output counts as JSON |
| `--session-out PATH` | `upload-batch`, `backfill-thumbnails`, `reconcile` | Write rotated session to PATH |
| `--exit-with-parent` | `upload-batch`, `backfill-thumbnails` | Stop if parent process exits |

## Architecture

Three components, one SQLite database as shared state:

```
menubar-app/    SwiftUI menu bar app — the GUI, owns credentials/Keychain
swift-helper/   CLI tool using PhotoKit — reads the local Photos library
go-uploader/    CLI tool — Proton auth, encryption, upload, all state
```

They communicate via subprocess + JSON on stdout, one line of progress per
stderr line. No shared memory, no sockets.

### Database

`~/Library/Application Support/photon-migrate/photon-migrate.db` (SQLite,
WAL mode, `0600` permissions). Holds the asset queue and status only.
Credentials live only in macOS Keychain — never in the database.

## Important notes

### Vendored dependencies

`go-uploader/third_party/` contains **modified forks** of `go-proton-api` and
`Proton-API-Bridge`. A `go get -u` will silently discard all patches and break
the build. See `HANDOFF.md` for the full list of modifications.

### App version string

Proton gates some endpoints on a minimum client version. This is currently
set to `macos-drive@3.0.2` in `internal/upload/upload.go`. If uploads start
failing with "outdated app" errors, check Proton's current release notes for
the real version number.

### License

This project is licensed under the GNU General Public License v3.0.
See [LICENSE](LICENSE) for the full text.
