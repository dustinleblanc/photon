package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"photon-migrate/internal/upload"

	papi "github.com/ProtonMail/go-proton-api"

	"photon-migrate/core"
	"photon-migrate/internal/asset"
	"photon-migrate/internal/store"
)

// dbPath is fixed to a location under the user's Application Support
// directory rather than a relative "photon-migrate.db" -- a relative path
// resolves against whatever directory the command happens to be invoked
// from, which silently splits state across multiple database files if the
// tool is run from different working directories (exactly what happened
// during development: CLI runs from go-uploader/ vs the project root ended
// up with two separate, out-of-sync databases).
var dbPath = func() string {
	if override := os.Getenv("PHOTON_MIGRATE_DB"); override != "" {
		return override
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "photon-migrate.db"
	}
	dir := filepath.Join(home, "Library", "Application Support", "photon-migrate")
	_ = os.MkdirAll(dir, 0o755)
	return filepath.Join(dir, "photon-migrate.db")
}()

func main() {
	if len(os.Args) < 2 {
		usage()
	}

	switch os.Args[1] {
	case "plan":
		cmdPlan()
	case "status":
		cmdStatus()
	case "upload":
		cmdUpload()
	case "upload-batch":
		cmdUploadBatch()
	case "upload-login":
		cmdUploadLogin()
	case "backfill-thumbnails":
		cmdBackfillThumbnails()
	case "reconcile":
		cmdReconcile()
	case "retry-failed":
		cmdRetryFailed()
	case "serve":
		cmdServe()
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: photon-migrate <command> [options]")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "commands:")
	fmt.Fprintln(os.Stderr, "  plan                reads JSONL from stdin (output of `photos-helper list`) and populates the status DB")
	fmt.Fprintln(os.Stderr, "  status              prints how many assets are pending/uploaded/skipped/failed")
	fmt.Fprintln(os.Stderr, "  upload-login        signs in and stores the session (requires PROTON_USERNAME/PASSWORD/2FA env vars)")
	fmt.Fprintln(os.Stderr, "  upload              uploads a single file from stdin -- see --filename/--modtime")
	fmt.Fprintln(os.Stderr, "  upload-batch        uploads every pending asset via photos-helper")
	fmt.Fprintln(os.Stderr, "  backfill-thumbnails re-uploads photos missing their thumbnail previews")
	fmt.Fprintln(os.Stderr, "  reconcile           marks pending assets as uploaded if they already exist on Proton")
	fmt.Fprintln(os.Stderr, "  retry-failed        resets failed assets to pending (optional: --error-substring X)")
	fmt.Fprintln(os.Stderr, "  serve               runs the loopback HTTP API for the Photon Library UI")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "options:")
	fmt.Fprintln(os.Stderr, "  --json              output counts as JSON")
	fmt.Fprintln(os.Stderr, "  --limit N           process at most N assets (upload-batch, backfill-thumbnails)")
	fmt.Fprintln(os.Stderr, "  --error-substring X only reset failures whose error contains X (retry-failed)")
	fmt.Fprintln(os.Stderr, "  --session-out PATH  write the (possibly rotated) session to PATH, 0600")
	fmt.Fprintln(os.Stderr, "  --exit-with-parent  stop if the parent process exits (used by the GUI)")
	fmt.Fprintln(os.Stderr, "  --addr HOST:PORT    serve bind address (serve; default 127.0.0.1:8787)")
	os.Exit(1)
}

func hasFlag(name string) bool {
	for _, a := range os.Args[2:] {
		if a == name {
			return true
		}
	}
	return false
}

// parseFlagInt looks for --name <value> in os.Args and returns the parsed
// integer. Returns (value, true) if found, or (defaultVal, false) if absent.
// Calls fatal() if the flag is present but the value is not a valid integer.
func parseFlagInt(name string, defaultVal int) (int, bool) {
	for i := 2; i < len(os.Args); i++ {
		if os.Args[i] == name && i+1 < len(os.Args) {
			val, err := strconv.Atoi(os.Args[i+1])
			if err != nil {
				fatal(fmt.Errorf("invalid value for %s: %q is not a number", name, os.Args[i+1]))
			}
			return val, true
		}
	}
	return defaultVal, false
}

// parseFlagString looks for --name <value> in os.Args and returns the value,
// or defaultVal if the flag is absent.
func parseFlagString(name string, defaultVal string) string {
	for i := 2; i < len(os.Args); i++ {
		if os.Args[i] == name && i+1 < len(os.Args) {
			return os.Args[i+1]
		}
	}
	return defaultVal
}

// parseFlagInt64 is like parseFlagInt but returns int64 (used for --modtime).
func parseFlagInt64(name string, defaultVal int64) (int64, bool) {
	for i := 2; i < len(os.Args); i++ {
		if os.Args[i] == name && i+1 < len(os.Args) {
			val, err := strconv.ParseInt(os.Args[i+1], 10, 64)
			if err != nil {
				fatal(fmt.Errorf("invalid value for %s: %q is not a number", name, os.Args[i+1]))
			}
			return val, true
		}
	}
	return defaultVal, false
}

// loginOutcome is the single JSON object cmdLogin always prints to stdout,
// so the caller (e.g. the menu bar app) can tell apart a completed login
// from "solve this human-verification challenge and retry" without
// scraping error text.
type loginOutcome struct {
	Status    string          `json:"status"` // "ok" | "hv_required"
	Session   *upload.Session `json:"session,omitempty"`
	HVToken   string          `json:"hvToken,omitempty"`
	HVMethods []string        `json:"hvMethods,omitempty"`
}

func printJSON(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		fatal(err)
	}
	fmt.Println(string(data))
}

// handleHVError checks whether err is an HVRequiredError (captcha needed)
// and, if so, prints the loginOutcome and returns true. Returns false for
// all other errors (which the caller should handle normally).
func handleHVError(err error) bool {
	var hvErr *upload.HVRequiredError
	if errors.As(err, &hvErr) {
		printJSON(loginOutcome{
			Status:    "hv_required",
			HVToken:   hvErr.Challenge.Token,
			HVMethods: hvErr.Challenge.Methods,
		})
		return true
	}
	return false
}

// uploadSessionName is the key the upload-stack session is stored under in
// the status DB's sessions table; uploadLockName guards against two batches
// running at once.
const (
	uploadSessionName = "upload"
	uploadLockName    = "upload"
)

// helperBinaryPath locates the Swift PhotoKit helper, in preference order:
//
//  1. PHOTOS_HELPER_PATH, for pointing at a local rebuild
//  2. alongside this binary -- how it ships, with both in the app bundle's
//     Contents/Resources, so neither needs to know an absolute path
//  3. relative to the repo root (found by walking up to a go.mod sentinel),
//     so any checkout location works
func helperBinaryPath() string {
	if override := os.Getenv("PHOTOS_HELPER_PATH"); override != "" {
		return override
	}

	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		beside := filepath.Join(filepath.Dir(exe), "photos-helper")
		if _, err := os.Stat(beside); err == nil {
			return beside
		}
	}

	// Walk upward from the executable to find the repo root (has go.mod),
	// then look for the helper in the expected build location.
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		dir := filepath.Dir(exe)
		for i := 0; i < 10; i++ {
			if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
				candidate := filepath.Join(dir, "..", "swift-helper", ".build", "debug", "photos-helper")
				if _, err := os.Stat(candidate); err == nil {
					return candidate
				}
				break
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}

	return "photos-helper" // last resort: hope it's on PATH
}

// watchParent stops the batch if whoever launched us goes away. macOS does
// not kill child processes when their parent exits, so without this a GUI
// crash (or a force-quit, where no cleanup handler runs) would leave a
// batch uploading invisibly in the background. When the parent dies the
// process is reparented to launchd, which is what the PID check detects.
func watchParent(stop func()) {
	originalParent := os.Getppid()
	go func() {
		for {
			time.Sleep(2 * time.Second)
			if os.Getppid() != originalParent {
				fmt.Fprintln(os.Stderr, "parent process exited, stopping batch")
				stop()
				return
			}
		}
	}()
}

// resolveUploadSession gets a usable Photos-share client with as little
// friction as possible, in this order:
//
//  1. PROTON_UPLOAD_SESSION_JSON, if set (explicit override, no fallback --
//     if you asked for a specific session, a silent fallback would hide
//     the fact that it didn't work)
//  2. the session stored in the DB by a previous run
//  3. a fresh username/password/2FA(/HV) login
//
// A stored session that no longer works (revoked, or a refresh token too
// old) falls through to (3) rather than failing, so the GUI never gets
// stuck needing a manual reset.
func resolveUploadSession(ctx context.Context) (*upload.Drive, *upload.SessionHolder, error) {
	if raw := os.Getenv("PROTON_UPLOAD_SESSION_JSON"); raw != "" {
		var saved upload.Session
		if err := json.Unmarshal([]byte(raw), &saved); err != nil {
			return nil, nil, fmt.Errorf("parse PROTON_UPLOAD_SESSION_JSON: %w", err)
		}
		return upload.Resume(ctx, saved)
	}

	username := os.Getenv("PROTON_USERNAME")
	password := os.Getenv("PROTON_PASSWORD")
	totp := os.Getenv("PROTON_2FA")
	hvToken := os.Getenv("PROTON_HV_TOKEN")
	hvMethod := os.Getenv("PROTON_HV_METHOD")
	if username == "" || password == "" {
		return nil, nil, fmt.Errorf("no PROTON_UPLOAD_SESSION_JSON, and PROTON_USERNAME/PROTON_PASSWORD are not set")
	}

	return upload.Login(ctx, username, password, totp, hvToken, hvMethod)
}

// sessionOutPath returns where to write the (possibly rotated) session, if
// the caller asked for one via --session-out <path>.
//
// This exists instead of printing the session: stdout/stderr end up in
// terminal scrollback, shell history buffers, and log files, all of which
// would then hold live credentials -- including saltedKeyPass, which is
// enough on its own to re-authenticate as the account. A caller that wants
// the rotated session back (the app, principally) supplies a private path
// of its own choosing and reads it after the process exits; a plain CLI
// invocation with no flag gets no exposure at all.
func sessionOutPath() string {
	for i := 2; i < len(os.Args); i++ {
		if os.Args[i] == "--session-out" && i+1 < len(os.Args) {
			return os.Args[i+1]
		}
	}
	return ""
}

// writeUploadSession persists the current session to --session-out, if one
// was given. Errors are reported but not fatal: failing to hand back a
// rotated token shouldn't undo a batch that otherwise completed.
func writeUploadSession(holder *upload.SessionHolder) {
	if holder == nil {
		return
	}
	path := sessionOutPath()
	if path == "" {
		return
	}
	data, err := json.Marshal(holder.Get())
	if err != nil {
		fmt.Fprintln(os.Stderr, "warning: failed to serialize upload session:", err)
		return
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		fmt.Fprintln(os.Stderr, "warning: failed to write session to", path+":", err)
	}
}

// cmdUploadLogin establishes the upload-stack session and stores it, doing
// no uploading. This is what the GUI calls once while it still has the
// password in memory; afterwards every other command resumes from the
// stored session with no credentials at all.
func cmdUploadLogin() {
	ctx := context.Background()

	s, err := store.Open(dbPath)
	if err != nil {
		fatal(err)
	}
	defer s.Close()

	_, holder, err := resolveUploadSession(ctx)
	if err != nil {
		if handleHVError(err) {
			return
		}
		fatal(err)
	}
	// Handed back on stdout so the caller can store it (the Keychain, for
	// the app) rather than leaving credentials in a file.
	session := holder.Get()
	printJSON(loginOutcome{Status: "ok", Session: &session})
}

// cmdUpload uploads a single file's bytes (read from stdin) into the
// account's Photos share -- a one-file-at-a-time primitive, kept around for
// testing the pipeline in isolation. It attaches no thumbnails; use
// upload-batch for real photo uploads.
//
// Usage:
//
//	photos-helper export "<localIdentifier>" | photon-migrate upload --filename "IMG_1234.heic" --modtime 1717000000
func cmdUpload() {
	var filename string
	for i := 2; i < len(os.Args); i++ {
		if os.Args[i] == "--filename" && i+1 < len(os.Args) {
			filename = os.Args[i+1]
			i++
		}
	}
	modTimeUnix, _ := parseFlagInt64("--modtime", 0)

	if filename == "" {
		fmt.Fprintln(os.Stderr, "usage: photon-migrate upload --filename <name> --modtime <unix-seconds> (reads file content from stdin)")
		os.Exit(1)
	}

	ctx := context.Background()

	s, err := store.Open(dbPath)
	if err != nil {
		fatal(err)
	}
	defer s.Close()

	drive, holder, err := resolveUploadSession(ctx)
	if err != nil {
		if handleHVError(err) {
			return
		}
		fatal(err)
	}
	defer writeUploadSession(holder)

	modTime := time.Unix(modTimeUnix, 0)
	linkID, err := upload.UploadOne(ctx, drive, filename, modTime, os.Stdin, nil)
	if err != nil {
		fatal(err)
	}

	printJSON(map[string]string{"status": "ok", "linkID": linkID})
}

// cmdUploadBatch walks the pending items in the status DB (both originals
// and edited renders), exporting each via `photos-helper export` and
// streaming the bytes straight into the upload -- no local disk staging,
// same zero-footprint design as the rest of this pipeline.
//
// Env: PROTON_USERNAME, PROTON_PASSWORD, PROTON_2FA, and (if a previous
// attempt returned hv_required) PROTON_HV_TOKEN/PROTON_HV_METHOD.
// Optional: --limit N (default: everything pending), PHOTOS_HELPER_PATH to
// override the photos-helper binary location.
func cmdUploadBatch() {
	limit, _ := parseFlagInt("--limit", 1_000_000)

	// Stop cleanly on Ctrl-C, or on the SIGTERM the GUI sends when you press
	// Stop: the loop finishes the file in flight and exits between items,
	// instead of being cut off mid-revision leaving an uncommitted draft.
	ctx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()

	if hasFlag("--exit-with-parent") {
		watchParent(stopSignals)
	}

	s, err := store.Open(dbPath)
	if err != nil {
		fatal(err)
	}
	defer s.Close()

	if err := s.AcquireLock(uploadLockName); err != nil {
		fatal(err)
	}
	defer s.ReleaseLock(uploadLockName)

	drive, holder, err := resolveUploadSession(ctx)
	if err != nil {
		if handleHVError(err) {
			return
		}
		fatal(err)
	}
	defer writeUploadSession(holder)

	// Save immediately as well as on exit: a long batch that gets
	// interrupted (or killed) should still leave a resumable session behind.
	writeUploadSession(holder)

	items, err := s.Pending(limit)
	if err != nil {
		fatal(err)
	}

	helperPath := helperBinaryPath()

	tally := runUploadQueue(ctx, drive, s, queueConfig{
		items:      items,
		helperPath: helperPath,
		checkDupes: true,
		verb:       "uploaded",
		record: func(item store.PendingItem, linkID string, thumbCount int) error {
			return s.MarkUploaded(item.LocalIdentifier, item.Version, "", linkID, thumbCount > 0)
		},
	})

	fmt.Printf("done: %d uploaded, %d skipped (already on Proton), %d failed\n",
		tally.uploaded.Load(), tally.skipped.Load(), tally.failed.Load())
}

// filenameForVersion disambiguates the edited render from the original so
// the two don't collide in the same folder (Proton would otherwise reject
// the second with a filename conflict).
func filenameForVersion(original string, version asset.Version) string {
	if version != asset.VersionEdited {
		return original
	}
	ext := filepath.Ext(original)
	base := strings.TrimSuffix(original, ext)
	return base + "_edited" + ext
}

// cmdBackfillThumbnails re-uploads photos that went up without previews.
//
// Thumbnails can only be attached while a revision is uploading, and the
// thumbnail endpoint is GET-only, so there is no way to add one to a
// committed revision. Re-uploading under the same filename creates a *new
// revision* on the existing link (the bridge's create-file path falls back
// to that when the name already exists), so the photo keeps its identity
// and no duplicate appears in the timeline. The dedup check is deliberately
// skipped here -- these are known duplicates, that's the point.
func cmdBackfillThumbnails() {
	limit, _ := parseFlagInt("--limit", 1_000_000)

	ctx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()

	if hasFlag("--exit-with-parent") {
		watchParent(stopSignals)
	}

	s, err := store.Open(dbPath)
	if err != nil {
		fatal(err)
	}
	defer s.Close()

	// Shares the upload lock: a backfill and a batch both upload, and
	// running them together would fight over the same photos.
	if err := s.AcquireLock(uploadLockName); err != nil {
		fatal(err)
	}
	defer s.ReleaseLock(uploadLockName)

	drive, holder, err := resolveUploadSession(ctx)
	if err != nil {
		if handleHVError(err) {
			return
		}
		fatal(err)
	}
	defer writeUploadSession(holder)

	items, err := s.NeedsThumbnails(limit)
	if err != nil {
		fatal(err)
	}
	if len(items) == 0 {
		fmt.Println("nothing to backfill: every uploaded photo already has thumbnails")
		return
	}

	helperPath := helperBinaryPath()

	tally := runUploadQueue(ctx, drive, s, queueConfig{
		items:        items,
		helperPath:   helperPath,
		checkDupes:   false, // these are known duplicates; that is the point
		requireThumb: true,  // re-uploading without a preview gains nothing
		verb:         "backfilled",
		record: func(item store.PendingItem, _ string, _ int) error {
			return s.MarkThumbnailed(item.LocalIdentifier, item.Version)
		},
	})

	fmt.Printf("done: %d backfilled, %d failed\n", tally.uploaded.Load(), tally.failed.Load())
}

// resolveNameCollision decides what to do when the Photos share already has
// a file whose name hashes the same as this one.
//
// A name match is not proof of a duplicate: camera filenames collide all
// the time across devices and counter rollovers. Proton's own client checks
// the content hash as well, and so do we -- skipping on the name alone
// would silently drop genuinely different photos from the migration.
//
// Returns (filenameToUse, existingLinkID, error). A non-empty existingLinkID
// means it really is already uploaded and should be skipped.
func resolveNameCollision(ctx context.Context, drive *upload.Drive, helperPath string, item store.PendingItem, filename string) (string, string, error) {
	matches, err := upload.FindDuplicatesByName(ctx, drive, filename)
	if err != nil {
		return filename, "", err
	}
	if len(matches) == 0 {
		return filename, "", nil
	}

	// Only now -- on an actual collision, which is rare -- is it worth
	// reading the asset an extra time to hash its contents.
	sha1Hex, err := hashAssetContent(ctx, helperPath, item)
	if err != nil {
		return filename, "", fmt.Errorf("hashing %s to check for a real duplicate: %w", filename, err)
	}
	contentHash, err := upload.PhotoContentHash(ctx, drive, sha1Hex)
	if err != nil {
		return filename, "", err
	}

	for _, match := range matches {
		if match.ContentHash != "" && match.ContentHash == contentHash {
			return filename, match.LinkID, nil // genuinely the same photo
		}
	}

	// Same name, different photo: find a free name rather than dropping it.
	candidate, err := upload.FindAvailableName(ctx, drive, filename, nil)
	if err != nil {
		return filename, "", err
	}
	return candidate, "", nil
}

// hashAssetContent streams the asset through SHA1 without buffering it,
// matching the digest Proton derives its content hash from.
func hashAssetContent(ctx context.Context, helperPath string, item store.PendingItem) (string, error) {
	args := []string{"export", item.LocalIdentifier}
	if item.Version == asset.VersionEdited {
		args = append(args, "--edited")
	}

	cmd := exec.CommandContext(ctx, helperPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		return "", err
	}

	digest := sha1.New()
	_, copyErr := io.Copy(digest, stdout)

	if waitErr := cmd.Wait(); waitErr != nil {
		return "", fmt.Errorf("export failed: %v: %s", waitErr, strings.TrimSpace(stderrBuf.String()))
	}
	if copyErr != nil {
		return "", copyErr
	}

	return hex.EncodeToString(digest.Sum(nil)), nil
}

// renderThumbnails asks the helper for the two preview sizes Proton's own
// clients upload. A thumbnail that fails to render is skipped rather than
// failing the whole asset: a photo with one preview (or none) is still
// better than not uploading it at all. Videos have no still to render, so
// this is best-effort by design.
func renderThumbnails(ctx context.Context, helperPath, localIdentifier string, version asset.Version) []upload.Thumbnail {
	var thumbnails []upload.Thumbnail

	for _, thumbType := range []int{papi.ThumbnailTypeDefault, papi.ThumbnailTypePhoto} {
		args := []string{"thumbnail", localIdentifier, "--type", strconv.Itoa(thumbType)}
		if version == asset.VersionEdited {
			args = append(args, "--edited")
		}

		thumbCtx, cancel := context.WithTimeout(ctx, thumbnailTimeout)
		cmd := exec.CommandContext(thumbCtx, helperPath, args...)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		err := cmd.Run()
		cancel()
		if err != nil {
			fmt.Fprintf(os.Stderr, "  thumbnail type %d unavailable for %s: %v: %s\n",
				thumbType, localIdentifier, err, strings.TrimSpace(stderr.String()))
			continue
		}
		if stdout.Len() == 0 {
			continue
		}

		thumbnails = append(thumbnails, upload.Thumbnail{
			Type: thumbType,
			Data: append([]byte(nil), stdout.Bytes()...),
		})
	}

	return thumbnails
}

// uploadOneFromHelper runs `photos-helper export <id> [--edited]` as a
// subprocess and streams its stdout directly into the upload -- the bytes
// never touch local disk.
// Returns the new link ID and how many thumbnails were actually attached --
// rendering is best-effort, and the caller must not record a photo as
// having previews when none made it.
func uploadOneFromHelper(ctx context.Context, drive *upload.Drive, helperPath, localIdentifier string, version asset.Version, filename string, modTime time.Time) (string, int, error) {
	thumbnails := renderThumbnails(ctx, helperPath, localIdentifier, version)

	args := []string{"export", localIdentifier}
	if version == asset.VersionEdited {
		args = append(args, "--edited")
	}

	cmd := exec.CommandContext(ctx, helperPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", 0, err
	}
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		return "", 0, err
	}

	// A stalled iCloud download otherwise blocks here forever: PhotoKit
	// offers no timeout, and the batch has no way to tell "large video" from
	// "wedged" except by watching the bytes.
	reader := newStallReader(stdout)
	stopWatchdog := watchForStall(reader, exportStallTimeout, func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}, fmt.Sprintf("export of %s", filename))

	linkID, uploadErr := upload.UploadOne(ctx, drive, filename, modTime, reader, thumbnails)
	stopWatchdog()

	if reader.bytesRead() == 0 {
		return "", 0, fmt.Errorf("%s exported 0 bytes -- the asset is probably not available locally or in iCloud", filename)
	}

	if waitErr := cmd.Wait(); waitErr != nil {
		return "", 0, fmt.Errorf("export failed: %v: %s", waitErr, strings.TrimSpace(stderrBuf.String()))
	}
	if uploadErr != nil {
		return "", 0, uploadErr
	}
	return linkID, len(thumbnails), nil
}

// captureTimeToleranceSeconds allows for minor rounding differences between
// PHAsset.creationDate (sub-second, local clock) and Proton's captureTime
// (whole-second, derived from EXIF at upload time).
const captureTimeToleranceSeconds = 1

func cmdReconcile() {
	ctx := context.Background()

	drive, holder, err := resolveUploadSession(ctx)
	if err != nil {
		if handleHVError(err) {
			return
		}
		fatal(err)
	}
	defer writeUploadSession(holder)

	fmt.Printf("found Photos volume: %s\n", upload.PhotosVolumeID(drive))

	remoteByTime, total, err := upload.FetchAllPhotoCaptureTimes(ctx, drive)
	if err != nil {
		fatal(err)
	}
	fmt.Printf("fetched %d photos already on Proton\n", total)

	s, err := store.Open(dbPath)
	if err != nil {
		fatal(err)
	}
	defer s.Close()

	pending, err := s.PendingOriginals()
	if err != nil {
		fatal(err)
	}

	matched := 0
	for _, item := range pending {
		linkID, ok := takeMatch(remoteByTime, item.CreationDate)
		if !ok {
			continue
		}
		if err := s.MarkUploaded(item.LocalIdentifier, item.Version, "", linkID, false); err != nil {
			fatal(err)
		}
		matched++
	}

	fmt.Printf("matched %d / %d pending originals against existing Proton Photos uploads\n", matched, len(pending))

	printCounts(s, hasFlag("--json"))
}

// takeMatch finds and consumes one remote linkID whose captureTime is within
// tolerance of localCreationDate, so the same remote photo is never matched
// to two different local assets.
func takeMatch(remoteByTime map[int64][]string, localCreationDate float64) (string, bool) {
	rd := int64(math.Round(localCreationDate))
	for _, t := range []int64{rd, rd - captureTimeToleranceSeconds, rd + captureTimeToleranceSeconds} {
		ids := remoteByTime[t]
		if len(ids) == 0 {
			continue
		}
		linkID := ids[0]
		remoteByTime[t] = ids[1:]
		return linkID, true
	}
	return "", false
}

func cmdPlan() {
	s, err := store.Open(dbPath)
	if err != nil {
		fatal(err)
	}
	defer s.Close()

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	count := 0
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var rec asset.Record
		if err := json.Unmarshal(line, &rec); err != nil {
			fmt.Fprintf(os.Stderr, "skipping malformed line: %v\n", err)
			continue
		}
		if err := s.Plan(rec); err != nil {
			fatal(err)
		}
		count++
	}
	if err := scanner.Err(); err != nil {
		fatal(err)
	}

	fmt.Printf("planned %d assets\n", count)
	printCounts(s, hasFlag("--json"))
}

func cmdStatus() {
	s, err := store.Open(dbPath)
	if err != nil {
		fatal(err)
	}
	defer s.Close()

	printCounts(s, hasFlag("--json"))
}

func cmdRetryFailed() {
	match := parseFlagString("--error-substring", "")

	s, err := store.Open(dbPath)
	if err != nil {
		fatal(err)
	}
	defer s.Close()

	n, err := s.RetryFailed(match)
	if err != nil {
		fatal(err)
	}
	fmt.Printf("reset %d failed assets to pending", n)
	if match != "" {
		fmt.Printf(" (error contains %q)", match)
	}
	fmt.Println()
	printCounts(s, hasFlag("--json"))
}

// cmdServe runs the loopback HTTP API for the Photon Library UI. It is bound
// to 127.0.0.1 only. A session already on disk (via --session-out) or in
// PROTON_UPLOAD_SESSION_JSON is resumed automatically; otherwise the UI logs
// in through POST /api/v1/auth/login.
func cmdServe() {
	addr := parseFlagString("--addr", "127.0.0.1:8787")
	sessionPath := sessionOutPath()

	srv := core.NewServer(func(s upload.Session) error {
		if sessionPath == "" {
			return nil
		}
		data, err := json.Marshal(s)
		if err != nil {
			return err
		}
		return os.WriteFile(sessionPath, data, 0o600)
	})

	// Resume a session we already have, so a relaunch doesn't require a fresh
	// login. Failures here are non-fatal: the UI can just sign in again.
	if raw := os.Getenv("PROTON_UPLOAD_SESSION_JSON"); raw != "" {
		var saved upload.Session
		if err := json.Unmarshal([]byte(raw), &saved); err == nil {
			if client, err := core.Resume(context.Background(), saved); err == nil {
				srv.SetSession(client, saved)
			}
		}
	}

	fmt.Fprintf(os.Stderr, "photon-serve listening on http://%s\n", addr)
	if err := srv.Serve(addr); err != nil {
		fatal(err)
	}
}

func printCounts(s *store.Store, asJSON bool) {
	counts, err := s.Counts()
	if err != nil {
		fatal(err)
	}
	if asJSON {
		data, err := json.Marshal(counts)
		if err != nil {
			fatal(err)
		}
		fmt.Println(string(data))
		return
	}
	fmt.Printf("pending=%d uploaded=%d skipped_duplicate=%d failed=%d\n",
		counts.Pending, counts.Uploaded, counts.SkippedDuplicate, counts.Failed)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
