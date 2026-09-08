# Vendored dependency patches

Both `go-proton-api` and `proton-api-bridge` under `third_party/` are
**modified forks**, not pristine vendoring. Both are MIT licensed.
Running `go get -u` will silently discard every patch below and break the
build in confusing ways.

This document exists so that anyone updating dependencies knows exactly
what was changed and why.

---

## go-proton-api (`third_party/go-proton-api/`)

Upstream: `github.com/henrybear327/go-proton-api` (MIT)

### New files

| File | Purpose |
|---|---|
| `photos.go` | `ShareTypePhotos` constant (value `4`, not in upstream enum), `ListPhotos` API endpoint (`GET /drive/volumes/{v}/photos`), `PhotosListResponsePhoto` type |
| `photos_duplicates.go` | `FindPhotoDuplicates` endpoint (`POST /drive/volumes/{v}/photos/duplicates`), `PhotoDuplicate` type |
| `block_verification_data.go` | `GetRevisionVerificationData` endpoint (`GET /drive/v2/volumes/{v}/links/{l}/revisions/{r}/verification`), returns `VerificationCode` needed for block uploads |
| `block_verify.go` | `VerificationCodeFromContentKeyPacket` (derives verification code for small-file path), `BuildVerificationToken` (XOR + base64 per-block token the server requires) |

### Modified files

| File | Change | Why |
|---|---|---|
| `block.go` | Added `RequestBlockAndThumbnailUpload` (returns `[]ThumbnailUploadLink` alongside `[]BlockUploadLink`) | Upstream only had `RequestBlockUpload` which discards thumbnail upload URLs. Photos need thumbnails attached during block upload — there is no API to add them after commit. |
| `block_types.go` | Added `ThumbnailList` to `BlockUploadReq`, `Verifier` to `BlockUploadInfo`, `BlockVerifier` type, `ThumbnailUploadInfo`/`ThumbnailUploadLink` types, `ThumbnailTypeDefault`/`ThumbnailTypePhoto` constants | The `/drive/blocks` endpoint requires a per-block `Verifier.Token` (absence triggers the misleading "outdated app" error). Thumbnails must be requested in the same block-upload call. |
| `link_types.go` | Added `XAttr string` field to `Link` struct | Cross-version compatibility with newer `Proton-API-Bridge` that expects `GetActiveRevisionAttrs` at the Link level. Not used by this project's upload path. |
| `link_file_types.go` | Added `Photo *CommitRevisionPhoto` plaintext field to `CommitRevisionReq`, `CommitRevisionPhoto` type, `ComputePhotoContentHash`, `RevisionXAttrCamera`, `RevisionXAttr.Camera` field, updated `SetEncXAttrString` to include Camera | Photos-share commits require: (a) a **plaintext** `Photo` field with `CaptureTime`/`ContentHash` (server can't decrypt XAttr), and (b) `CaptureTime` in the encrypted XAttr. Missing either produces opaque errors (Code=2511). |
| `address.go` | Changed `slices.SortFunc` call to use `func(a, b Address) int` signature | Signature drift between this fork and the `golang.org/x/exp/slices` version used. |

---

## proton-api-bridge (`third_party/proton-api-bridge/`)

Upstream: `github.com/henrybear327/Proton-API-Bridge` (MIT)

### New files

| File | Purpose |
|---|---|
| `photos_bootstrap.go` | `NewProtonDriveForPhotos` (bootstraps against the Photos-type share/volume instead of main Drive — same upload endpoints, just targeting `ShareType=4`), `ListPhotos` wrapper |
| `photos_duplicate_check.go` | `FindDuplicatesByName` (content-hash-aware dedup), `FindAvailableName` (batched collision resolution — 20 candidates per API call instead of probing one at a time), `PhotoContentHash` (HMAC-SHA256 over SHA1 hex, matching Proton's formula) |

### Modified files

| File | Change | Why |
|---|---|---|
| `file_upload.go` | Added `Thumbnail`/`encryptedThumbnail` types, `encryptThumbnails`, `UploadFileByReaderWithThumbnails`, thumbnail handling in `uploadAndCollectBlockData`, manifest signature ordering (thumbnail hashes sorted by type **then** content block hashes), `CommitRevisionPhoto` plaintext field wiring, `ReplaceExistingDraft` draft-replacement logic, `GetRevisionVerificationData` call in `createFileUploadDraft` | (1) Thumbnails must be encrypted and uploaded in the same block-upload request. (2) Wrong manifest order = opaque signature verification failure. (3) The `Photo` plaintext field is required for Photos-share commits. (4) Without `ReplaceExistingDraft=true`, a retry after partial upload hits "draft already exists" and fails permanently. (5) Block verification token requires server-provided verification code. |
| `common/config.go` | Added `HVToken`/`HVMethod` fields to `FirstLoginCredentialData`, `ReplaceExistingDraft` field, `CredentialCacheFile` comment | HV (captcha) token support for retrying login after challenge. `ReplaceExistingDraft` defaults to `false` upstream but must be `true` for this project. `CredentialCacheFile` is dead code in this project — never set — but exists in upstream; do not enable it (writes plaintext credentials to disk). |
| `common/user.go` | Added `HVChallenge`/`HVRequiredError` types, `extractHVChallenge`, HV header injection in `Login` via `PreRequestHook` (`x-pm-human-verification-token-type` + `x-pm-human-verification-token`) | Handles Proton's human verification (captcha) flow. Reverse-engineered from Proton's open-sourced `protoncore_ios` (`APIClient/TestAPI.swift`). |

---

## Before you update dependencies

1. Read this file.
2. Run `git diff HEAD -- third_party/` to see the exact current state of every patch.
3. Apply patches incrementally, testing after each one. The protocol-level
   patches (verification tokens, manifest ordering, plaintext Photo field)
   are the ones that cause silent failures when missing.
4. Update this file with any new patches.
