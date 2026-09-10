# Vendored Dependency Patches

Patches live as commits on GitHub forks. `go.mod` uses `replace` directives to
pull from these forks instead of upstream.

## Forks

| Upstream | Fork | Fork Tag |
|---|---|---|
| `github.com/ProtonMail/go-proton-api` | `github.com/dustinleblanc/go-proton-api` | `v0.4.1-photon.2` |
| `github.com/henrybear327/Proton-API-Bridge` | `github.com/dustinleblanc/Proton-API-Bridge` | `v1.0.0-photon.1` |

Upstream base: `henrybear327/go-proton-api@dev_2025_01_27` (67bd01ad0bc3),
`henrybear327/Proton-API-Bridge@master` (1.0.0).

## go-proton-api patches

### `photos.go` — Photos API endpoints
- `ShareTypePhotos` constant (`ShareType = 4`)
- `ListPhotos()` — paginated photo listing with non-success error handling

### `photos_duplicates.go` — Content-hash dedup
- `FindPhotoDuplicates()` — finds duplicate photos via content hash

### `block_verification_data.go` — Server verification tokens
- `GetRevisionVerificationData()` — gets verification tokens for revision commit
- `BuildVerificationToken()` / `VerificationCodeFromContentKeyPacket()` — HMAC-based token construction

### `block.go` — Block upload with thumbnails
- `RequestBlockAndThumbnailUpload()` — combined block + thumbnail upload request
- Block-level `ThumbnailList` support

### `block_types.go` — Thumbnail + verifier types
- `ThumbnailReq`, `ThumbnailResp`, `ThumbnailList`, `BlockVerifier` structs
- `EncryptedThumbnail` / `DecryptedThumbnail` types

### `link_file_types.go` — Photo commit fields
- `CommitRevisionPhoto` struct with `Photo` (plaintext) field
- `ComputePhotoContentHash()` — SHA-256 content hash
- `RevisionXAttrCamera` — camera metadata XAttr struct

### `link_types.go` — XAttr field
- `XAttr` field on `Link` struct (cross-version compatibility)

### `address.go` — Sort signature fix
- `slices.SortFunc` signature updated for newer Go version

## Proton-API-Bridge patches

### `photos_bootstrap.go` — Photos mode bootstrap
- `NewProtonDriveForPhotos()` — bootstraps against ShareType=4 instead of Drive

### `photos_duplicate_check.go` — Dedup resolution
- `FindDuplicatesByName()` — content-hash-aware batched duplicate finding
- `FindAvailableName()` — batched collision resolution

### `file_upload.go` — Thumbnail + manifest fixes
- Thumbnail fields on `UploadFileBlockResp`
- Manifest hash ordering fix (sorted keys for deterministic signing)
- Draft replacement logic (`ReplaceExistingDraft`)
- `Photo` field passed through on commit

### `common/config.go` — HV captcha config
- `HVToken` / `HVMethod` fields
- `ReplaceExistingDraft` flag

### `common/user.go` — HV captcha headers
- `HVChallenge` / `HVRequiredError` types
- `doHVRequiredHeader()` — injects HV captcha headers into requests

## Updating upstream

```bash
# 1. Update upstream ref in the fork
cd /tmp/go-proton-api
git remote add upstream https://github.com/henrybear327/go-proton-api.git
git fetch upstream
git rebase upstream/dev_2025_01_27

# 2. Tag and push
git tag -a v0.4.1-photon.3 -m "Rebase on upstream"
git push origin dev_2025_01_27 --tags

# 3. Update go.mod in photon
# Change the replace directive to point at the new tag
```
