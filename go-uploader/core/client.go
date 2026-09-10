package core

import (
	"context"
	"io"

	papi "github.com/ProtonMail/go-proton-api"

	"photon-migrate/internal/upload"
)

// Client is the concrete ProtonClient over the reverse-engineered bridge. It
// holds a live session (with token rotation) plus the scoped Photos-share
// drive. Construct via Login or Resume.
type Client struct {
	drive  *upload.Drive
	holder *upload.SessionHolder
}

// Login performs a fresh SRP login (optionally completing a human-verification
// challenge) and returns the client plus the session to persist for future
// Resume calls.
func Login(ctx context.Context, username, password, totp, hvToken, hvMethod string) (*Client, upload.Session, error) {
	drive, holder, err := upload.Login(ctx, username, password, totp, hvToken, hvMethod)
	if err != nil {
		return nil, upload.Session{}, err
	}
	return &Client{drive: drive, holder: holder}, holder.Get(), nil
}

// Resume re-establishes a client from a previously persisted session, avoiding
// a password/2FA/captcha round-trip. Tokens refresh automatically.
func Resume(ctx context.Context, saved upload.Session) (*Client, error) {
	drive, holder, err := upload.Resume(ctx, saved)
	if err != nil {
		return nil, err
	}
	return &Client{drive: drive, holder: holder}, nil
}

// Session returns the current (possibly rotated) session, so the caller can
// persist it after use.
func (c *Client) Session() upload.Session {
	return c.holder.Get()
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

// OpenOriginal streams the decrypted original for a photo link. The returned
// size is the plaintext byte length (for Content-Length).
func (c *Client) OpenOriginal(ctx context.Context, linkID string) (io.ReadCloser, int64, error) {
	rc, size, _, err := c.drive.DownloadFileByID(ctx, linkID, 0)
	if err != nil {
		return nil, 0, err
	}
	return rc, size, nil
}

// FetchPreview returns a rendered JPEG preview for a photo. Not implemented in
// M0: the bridge has no thumbnail-download path yet, so callers must fall back
// to OpenOriginal.
func (c *Client) FetchPreview(ctx context.Context, linkID string, size int) ([]byte, error) {
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
