package core

import (
	"context"
	"errors"
	"io"
	"sync"

	papi "github.com/ProtonMail/go-proton-api"

	"photon/proton"
)

// Client is the concrete ProtonClient over the reverse-engineered bridge. It
// holds a live session (with token rotation) plus the scoped Photos-share
// drive. Construct via Login or Resume.
type Client struct {
	drive  *proton.Drive
	holder *proton.SessionHolder

	// files is the account's regular Drive (the Photos share rejects
	// non-photo content), created lazily on first use and guarded because
	// construction performs network calls.
	filesMu sync.Mutex
	files   *proton.Drive

	// onRotate, when set, is invoked with the fresh session after every
	// token rotation so long-running processes can persist it.
	onRotate func(proton.Session)
}

// OnRotate registers a callback invoked whenever the underlying session's
// tokens rotate. Must be called before the client sees traffic. Safe on a
// zero-value Client (tests construct bare ones with no live session).
func (c *Client) OnRotate(fn func(proton.Session)) {
	c.onRotate = fn
	if c.holder != nil {
		c.holder.OnRotate(fn)
	}
}

// Login performs a fresh SRP login (optionally completing a human-verification
// challenge) and returns the client plus the session to persist for future
// Resume calls. onRotate, when non-nil, fires on every token rotation
// (registered before the login flow starts, so no rotation is missed).
func Login(ctx context.Context, username, password, totp, hvToken, hvMethod string, onRotate func(proton.Session)) (*Client, proton.Session, error) {
	drive, holder, err := proton.Login(ctx, username, password, totp, hvToken, hvMethod, onRotate)
	if err != nil {
		return nil, proton.Session{}, err
	}
	return &Client{drive: drive, holder: holder}, holder.Get(), nil
}

// Resume re-establishes a client from a previously persisted session, avoiding
// a password/2FA/captcha round-trip. Tokens refresh automatically.
func Resume(ctx context.Context, saved proton.Session, onRotate func(proton.Session)) (*Client, error) {
	drive, holder, err := proton.Resume(ctx, saved, onRotate)
	if err != nil {
		return nil, err
	}
	return &Client{drive: drive, holder: holder}, nil
}

// Session returns the current (possibly rotated) session, so the caller can
// persist it after use.
func (c *Client) Session() proton.Session {
	return c.holder.Get()
}

// Drive exposes the underlying Photos-share drive for features that talk to
// Drive directly.
func (c *Client) Drive() *proton.Drive {
	return c.drive
}

// FilesDrive returns the account's regular Drive, creating it on first use.
// Used for app-owned files (people-tags snapshot) that cannot live in the
// photo-only share.
func (c *Client) FilesDrive(ctx context.Context) (*proton.Drive, error) {
	c.filesMu.Lock()
	defer c.filesMu.Unlock()
	if c.files != nil {
		return c.files, nil
	}
	if c.holder == nil {
		return nil, errors.New("no session")
	}
	drive, err := proton.NewFilesDrive(ctx, c.holder.Get(), c.holder)
	if err != nil {
		return nil, err
	}
	c.files = drive
	return drive, nil
}

// ListPhotos returns a page of the Photos timeline. cursor is the
// "previous page last link id" (pass the last photo's LinkID to page forward).
func (c *Client) ListPhotos(ctx context.Context, cursor string, pageSize int) ([]Photo, error) {
	if pageSize <= 0 {
		pageSize = 500
	}
	raw, err := c.drive.ListPhotos(ctx, cursor, pageSize)
	if err != nil {
		return nil, err
	}
	photos := make([]Photo, 0, len(raw))
	for _, p := range raw {
		photos = append(photos, toPhoto(p))
	}
	return photos, nil
}

// OpenOriginal streams the decrypted original for a photo link.
//
// The returned size is NOT the plaintext byte length: go-proton-api reports the
// block-padded encrypted size, which can be larger than the honestly decrypted
// content (e.g. ~4.5M for a ~3.9M HEIC). Callers must not advertise it as
// Content-Length; stream the body and let the length come from the wire.
func (c *Client) OpenOriginal(ctx context.Context, linkID string) (io.ReadCloser, int64, error) {
	rc, size, _, err := c.drive.DownloadFileByID(ctx, linkID, 0)
	if err != nil {
		return nil, 0, err
	}
	return rc, size, nil
}

// FetchPreview returns a rendered JPEG preview for a photo, decrypted
// client-side from the encrypted thumbnail Proton stores. size selects the
// thumbnail tier: <=512px uses the "default" (512px) preview, larger uses the
// "photo" (1920px) HD preview. Falls back to a lower tier if the requested one
// is missing.
func (c *Client) FetchPreview(ctx context.Context, linkID string, size int) ([]byte, error) {
	preferred := papi.ThumbnailTypePhoto
	if size <= 512 {
		preferred = papi.ThumbnailTypeDefault
	}

	// Try the preferred tier first, then the other, so a photo missing its HD
	// preview still gets a thumbnail rather than a full-original download.
	for _, tier := range []int{preferred, papi.ThumbnailTypeDefault + papi.ThumbnailTypePhoto - preferred} {
		data, err := c.drive.DownloadThumbnail(ctx, linkID, tier)
		if err == nil {
			return data, nil
		}
		if errors.Is(err, proton.ErrNoThumbnail) {
			continue
		}
		return nil, err
	}
	return nil, ErrPreviewUnavailable
}

func toPhoto(p papi.PhotosListResponsePhoto) Photo {
	photo := Photo{
		LinkID:      p.LinkID,
		CaptureTime: p.CaptureTime,
		AddedTime:   p.AddedTime,
		Hash:        p.Hash,
		ContentHash: p.ContentHash,
		Tags:        p.Tags,
	}
	for _, r := range p.RelatedPhotos {
		photo.RelatedPhotos = append(photo.RelatedPhotos, toPhoto(r))
	}
	return photo
}
