package upload

import (
	"context"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	papi "github.com/ProtonMail/go-proton-api"
	bridge "github.com/henrybear327/Proton-API-Bridge"
	"github.com/henrybear327/Proton-API-Bridge/common"
)

// HVRequiredError re-exports the vendored bridge's HV signal so callers in
// this module don't need to import the bridge's common package directly.
type HVRequiredError = common.HVRequiredError

// ErrNoThumbnail re-exports the bridge's "no preview of this type" signal,
// which FetchPreview uses to fall back across thumbnail tiers.
var ErrNoThumbnail = bridge.ErrNoThumbnail

// Drive re-exports *bridge.ProtonDrive so callers don't need to import the
// bridge package directly just to hold a reference to it between calls.
type Drive = bridge.ProtonDrive

const appVersion = "macos-drive@3.0.2"

// Session is what's needed to resume this login stack without a fresh
// password/2FA/captcha round-trip. SaltedKeyPass is the password-derived
// value used to re-decrypt the user's keyring on resume -- it is not the
// password itself, but treat it with the same care as a session token.
type Session struct {
	UID           string `json:"uid"`
	AccessToken   string `json:"accessToken"`
	RefreshToken  string `json:"refreshToken"`
	SaltedKeyPass string `json:"saltedKeyPass"`
}

// SessionHolder hands back the *current* session rather than a snapshot.
// Proton rotates tokens whenever the client refreshes an expired access
// token mid-run, which for a multi-hour batch is a near certainty -- if the
// caller persisted the value from login time, the next run's resume would
// fail with stale tokens. The mutex is needed because the auth handler
// fires from the bridge's concurrent block-upload goroutines.
type SessionHolder struct {
	mu      sync.Mutex
	session Session
}

func (h *SessionHolder) Get() Session {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.session
}

func (h *SessionHolder) setTokens(uid, accessToken, refreshToken string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.session.UID = uid
	h.session.AccessToken = accessToken
	h.session.RefreshToken = refreshToken
}

func (h *SessionHolder) set(session Session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.session = session
}

// Login performs a full SRP login (optionally completing a human
// verification challenge) and bootstraps a ProtonDrive scoped to the
// account's Photos share. Returns a Session to persist for future Resume
// calls, so subsequent runs don't need the password/2FA/captcha again.
func Login(ctx context.Context, username, password, totp, hvToken, hvMethod string) (*Drive, *SessionHolder, error) {
	config := common.NewConfigWithDefaultValues()
	config.AppVersion = appVersion
	// A retry after a partly-uploaded revision would otherwise hit "draft
	// already exists" and fail permanently, which defeats retrying at all.
	config.ReplaceExistingDraft = true
	config.FirstLoginCredential = &common.FirstLoginCredentialData{
		Username: username,
		Password: password,
		TwoFA:    totp,
		HVToken:  hvToken,
		HVMethod: hvMethod,
	}

	holder := &SessionHolder{}
	authHandler := func(auth papi.Auth) {
		holder.setTokens(auth.UID, auth.AccessToken, auth.RefreshToken)
	}

	drive, cred, err := bridge.NewProtonDriveForPhotos(ctx, config, authHandler, func() {})
	if err != nil {
		return nil, nil, err
	}
	if cred != nil {
		holder.set(Session{
			UID:           cred.UID,
			AccessToken:   cred.AccessToken,
			RefreshToken:  cred.RefreshToken,
			SaltedKeyPass: cred.SaltedKeyPass,
		})
	}
	return drive, holder, nil
}

// Resume re-establishes a ProtonDrive from a previously persisted Session,
// avoiding a password/2FA/captcha round-trip. The access token refreshes
// automatically (via the client's built-in 401 handling) if it has expired;
// the returned Session reflects any such rotation, so callers should
// persist it again after use.
func Resume(ctx context.Context, saved Session) (*Drive, *SessionHolder, error) {
	// SaltedKeyPass is what unlocks the user's keyring. Without it the
	// bridge fails deep in the crypto with "private key checksum failure",
	// which gives no hint that the session is simply incomplete -- as
	// happens with one written by an older version of this tool.
	if saved.SaltedKeyPass == "" || saved.UID == "" || saved.RefreshToken == "" {
		return nil, nil, fmt.Errorf("stored session is incomplete (missing %s) -- sign in again to replace it", missingSessionFields(saved))
	}

	config := common.NewConfigWithDefaultValues()
	config.AppVersion = appVersion
	// A retry after a partly-uploaded revision would otherwise hit "draft
	// already exists" and fail permanently, which defeats retrying at all.
	config.ReplaceExistingDraft = true
	config.UseReusableLogin = true
	config.ReusableCredential = &common.ReusableCredentialData{
		UID:           saved.UID,
		AccessToken:   saved.AccessToken,
		RefreshToken:  saved.RefreshToken,
		SaltedKeyPass: saved.SaltedKeyPass,
	}

	holder := &SessionHolder{session: saved}
	authHandler := func(auth papi.Auth) {
		holder.setTokens(auth.UID, auth.AccessToken, auth.RefreshToken)
	}

	drive, _, err := bridge.NewProtonDriveForPhotos(ctx, config, authHandler, func() {})
	if err != nil {
		return nil, nil, err
	}
	return drive, holder, nil
}

func missingSessionFields(s Session) string {
	var missing []string
	if s.UID == "" {
		missing = append(missing, "uid")
	}
	if s.RefreshToken == "" {
		missing = append(missing, "refreshToken")
	}
	if s.SaltedKeyPass == "" {
		missing = append(missing, "saltedKeyPass")
	}
	return strings.Join(missing, ", ")
}

// Thumbnail re-exports the bridge's rendered-preview type.
type Thumbnail = bridge.Thumbnail

// UploadOne uploads a single file's content into the root of the Photos
// share. filename/modTime feed into the encrypted name and XAttr metadata
// (modification time) Proton stores alongside the file.
//
// Thumbnails must be supplied here: they can only be attached while the
// revision is being uploaded, and there is no API to add them afterwards,
// so a photo uploaded without them has no preview in the Photos timeline
// for good.
func UploadOne(ctx context.Context, drive *Drive, filename string, modTime time.Time, data io.Reader, thumbnails []Thumbnail) (string, error) {
	linkID, _, err := drive.UploadFileByReaderWithThumbnails(ctx, drive.RootLink.LinkID, filename, modTime, data, thumbnails)
	if err != nil {
		return "", err
	}
	return linkID, nil
}

// DuplicateMatch re-exports the bridge's name-collision result.
type DuplicateMatch = bridge.DuplicateMatch

// FindDuplicatesByName returns existing photos whose filename hashes to the
// same value. A name match alone is NOT proof of a duplicate: compare
// ContentHash (see PhotoContentHash) before skipping anything, or photos
// that merely share a camera filename get silently dropped.
func FindDuplicatesByName(ctx context.Context, drive *Drive, filename string) ([]DuplicateMatch, error) {
	return drive.FindDuplicatesByName(ctx, filename)
}

// FindAvailableName returns a free "name (n).ext" variant for a filename
// already taken by a different photo.
func FindAvailableName(ctx context.Context, drive *Drive, filename string, isReserved func(string) bool) (string, error) {
	return drive.FindAvailableName(ctx, filename, isReserved)
}

// PhotoContentHash converts the SHA1 of an asset's plaintext contents into
// the content hash Proton stores, for comparison against a DuplicateMatch.
func PhotoContentHash(ctx context.Context, drive *Drive, sha1Hex string) (string, error) {
	return drive.PhotoContentHash(ctx, sha1Hex)
}

const photoPageSize = 500

// FetchAllPhotoCaptureTimes indexes every photo already in the account's
// Photos volume by capture time -- a plain Unix timestamp, unlike the
// name/content hashes, which are derived from encrypted data. Used to
// reconcile local assets against a backup made previously by Proton's own
// apps, where filenames may not line up.
func FetchAllPhotoCaptureTimes(ctx context.Context, drive *Drive) (map[int64][]string, int, error) {
	byTime := make(map[int64][]string)
	lastID := ""
	total := 0

	for {
		photos, err := drive.ListPhotos(ctx, lastID, photoPageSize)
		if err != nil {
			return nil, 0, fmt.Errorf("list photos: %w", err)
		}
		if len(photos) == 0 {
			break
		}

		for _, p := range photos {
			byTime[p.CaptureTime] = append(byTime[p.CaptureTime], p.LinkID)
			total++
			for _, related := range p.RelatedPhotos {
				byTime[related.CaptureTime] = append(byTime[related.CaptureTime], related.LinkID)
				total++
			}
		}

		lastID = photos[len(photos)-1].LinkID
		if len(photos) < photoPageSize {
			break
		}
	}

	return byTime, total, nil
}

// PhotosVolumeID is the volume the session is scoped to.
func PhotosVolumeID(drive *Drive) string { return drive.MainShare.VolumeID }
