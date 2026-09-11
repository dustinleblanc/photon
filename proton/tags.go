package proton

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	papi "github.com/ProtonMail/go-proton-api"
)

// The people-tags snapshot lives as a single small file inside an app-owned
// folder in the account's regular Drive (the Photos share rejects non-photo
// content), so every device signed into the account sees the same
// identities. The file is E2E-encrypted by Drive like everything else; the
// sync protocol (revision counters, conflict handling) lives in core, this
// file is only the Drive I/O.
const (
	TagsFolderName = "Photon Library"
	TagsFileName   = "tags.json"
)

// ErrTagsNotFound is returned by DownloadTags when no snapshot exists yet.
var ErrTagsNotFound = errors.New("tags file not found")

// ensureTagsFolder returns the app-owned folder, creating it when missing.
func ensureTagsFolder(ctx context.Context, drive *Drive) (*papi.Link, error) {
	folder, err := drive.SearchByNameInActiveFolderByID(
		ctx, drive.RootLink.LinkID, TagsFolderName, false, true, papi.LinkStateActive,
	)
	if err != nil {
		return nil, fmt.Errorf("search tags folder: %w", err)
	}
	if folder != nil {
		return folder, nil
	}
	folderID, err := drive.CreateNewFolderByID(ctx, drive.RootLink.LinkID, TagsFolderName)
	if err != nil {
		return nil, fmt.Errorf("create tags folder: %w", err)
	}
	return drive.GetLink(ctx, folderID)
}

// findTagsFile returns the tags.json link, or nil when it doesn't exist.
func findTagsFile(ctx context.Context, drive *Drive, folderLinkID string) (*papi.Link, error) {
	file, err := drive.SearchByNameInActiveFolderByID(
		ctx, folderLinkID, TagsFileName, true, false, papi.LinkStateActive,
	)
	if err != nil {
		return nil, fmt.Errorf("search tags file: %w", err)
	}
	return file, nil
}

// DownloadTags fetches the decrypted tags snapshot. ErrTagsNotFound when the
// file (or its folder) doesn't exist yet.
func DownloadTags(ctx context.Context, drive *Drive) ([]byte, error) {
	folder, err := ensureTagsFolder(ctx, drive)
	if err != nil {
		return nil, err
	}
	file, err := findTagsFile(ctx, drive, folder.LinkID)
	if err != nil {
		return nil, err
	}
	if file == nil {
		return nil, ErrTagsNotFound
	}
	rc, _, _, err := drive.DownloadFileByID(ctx, file.LinkID, 0)
	if err != nil {
		return nil, fmt.Errorf("download tags: %w", err)
	}
	defer rc.Close()
	data, err := io.ReadAll(rc)
	if err != nil {
		return nil, fmt.Errorf("read tags: %w", err)
	}
	return data, nil
}

// UploadTags writes a new revision of the snapshot: the new file is uploaded
// first, then the previous link is trashed, so a failed upload never destroys
// the existing data. Drive permits same-name files in a folder, which is why
// the old link is removed explicitly.
func UploadTags(ctx context.Context, drive *Drive, data []byte) error {
	folder, err := ensureTagsFolder(ctx, drive)
	if err != nil {
		return err
	}
	old, err := findTagsFile(ctx, drive, folder.LinkID)
	if err != nil {
		return err
	}
	reader := newByteReader(data)
	if _, _, err := drive.UploadFileByReader(
		ctx, folder.LinkID, TagsFileName, time.Now(), reader, 0,
	); err != nil {
		return fmt.Errorf("upload tags: %w", err)
	}
	if old != nil {
		if err := drive.MoveFileToTrashByID(ctx, old.LinkID); err != nil {
			// The new revision is already in place; a stale copy lingering
			// under the same name is confusing but not data loss. Surface it
			// so the caller can log it.
			return fmt.Errorf("trash previous tags revision: %w", err)
		}
	}
	return nil
}

// byteReader adapts a byte slice to io.Reader without copying.
type byteReader struct {
	data []byte
	pos  int
}

func newByteReader(data []byte) *byteReader { return &byteReader{data: data} }

func (r *byteReader) Read(p []byte) (int, error) {
	if r.pos >= len(r.data) {
		return 0, io.EOF
	}
	n := copy(p, r.data[r.pos:])
	r.pos += n
	return n, nil
}
