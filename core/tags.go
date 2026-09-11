package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"photon/proton"
)

// The people-tags sync document: one JSON file per account, holding every
// named identity (canonical name, aliases, centroid embedding, sample count).
// Embeddings are engine-specific vectors, but all current platforms run the
// same MobileFaceNet model, so centroids transfer between devices as-is.
// Contact links are deliberately NOT synced: a contact id is meaningless
// outside the device that created it.
//
// The snapshot lives in the account's regular Drive (the Photos share
// rejects non-photo content with a 422), E2E-encrypted at rest like every
// other file.
//
// Sync is last-writer-wins per identity with client-side merge: the document
// carries a monotonically increasing revision, PUT is rejected with a 409
// carrying the current document when the client's base revision is stale, and
// the client merges remote identities into its local index before retrying.

// ErrNoTags is returned by TagsStore.Load when no snapshot exists yet.
var ErrNoTags = errors.New("no tags snapshot")

// ErrRevisionConflict is returned by the server when a PUT is based on a
// stale revision.
var ErrRevisionConflict = errors.New("tags revision conflict")

// TagsIdentity is one person in the sync document.
type TagsIdentity struct {
	Name     string    `json:"name"`
	Aliases  []string  `json:"aliases,omitempty"`
	Centroid []float32 `json:"centroid"`
	Samples  int       `json:"samples"`
}

// TagsDocument is the full snapshot payload.
type TagsDocument struct {
	Revision   int64          `json:"revision"`
	UpdatedAt  int64          `json:"updatedAt"`
	Identities []TagsIdentity `json:"identities"`
}

// TagsStore persists the raw document bytes. Load returns ErrNoTags when no
// snapshot exists yet.
type TagsStore interface {
	Load(ctx context.Context) ([]byte, error)
	Save(ctx context.Context, data []byte) error
}

// DriveTagsStore stores the snapshot in the account's own Drive (E2E
// encrypted at rest like every other file).
type DriveTagsStore struct{}

func (DriveTagsStore) Load(ctx context.Context) ([]byte, error) {
	data, err := proton.DownloadTags(ctx, tagsDrive(ctx))
	if err != nil {
		if errors.Is(err, proton.ErrTagsNotFound) {
			return nil, ErrNoTags
		}
		return nil, err
	}
	return data, nil
}

func (DriveTagsStore) Save(ctx context.Context, data []byte) error {
	return proton.UploadTags(ctx, tagsDrive(ctx), data)
}

// tagsDrive pulls the regular *proton.Drive out of the context; the server
// wires it in per request because the client (and its session) can change at
// runtime, and the drive itself is created lazily on first use.
type driveKeyT struct{}

var driveKey driveKeyT

func WithDrive(ctx context.Context, drive *proton.Drive) context.Context {
	return context.WithValue(ctx, driveKey, drive)
}

func tagsDrive(ctx context.Context) *proton.Drive {
	drive, _ := ctx.Value(driveKey).(*proton.Drive)
	return drive
}

// parseTagsDocument decodes a stored snapshot, tolerating an empty file.
func parseTagsDocument(data []byte) (TagsDocument, error) {
	var doc TagsDocument
	if len(data) == 0 {
		return doc, nil
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return doc, fmt.Errorf("parse tags document: %w", err)
	}
	return doc, nil
}

// getTags handles GET /api/v1/tags. A missing snapshot reads as revision 0
// with no identities, so clients don't need to special-case 404.
func (s *Server) getTags(w http.ResponseWriter, r *http.Request) {
	client := s.currentClient()
	if client == nil {
		writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	ctx := r.Context()
	files, err := s.driveFor(ctx, client)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "open drive: "+err.Error())
		return
	}
	data, err := s.tags.Load(WithDrive(ctx, files))
	if err != nil && !errors.Is(err, ErrNoTags) {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	doc, err := parseTagsDocument(data)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, doc)
}

type putTagsRequest struct {
	BaseRevision int64          `json:"baseRevision"`
	Identities   []TagsIdentity `json:"identities"`
}

type putTagsResponse struct {
	Revision int64 `json:"revision"`
}

// putTags handles PUT /api/v1/tags with optimistic concurrency: the write is
// accepted only when the stored revision still equals the client's base; a
// 409 carries the current document so the client can merge and retry.
func (s *Server) putTags(w http.ResponseWriter, r *http.Request) {
	client := s.currentClient()
	if client == nil {
		writeError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	ctx := r.Context()
	files, err := s.driveFor(ctx, client)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "open drive: "+err.Error())
		return
	}
	var req putTagsRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, 16<<20)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid body: "+err.Error())
		return
	}

	currentData, err := s.tags.Load(WithDrive(ctx, files))
	if err != nil && !errors.Is(err, ErrNoTags) {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	current, err := parseTagsDocument(currentData)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if current.Revision != req.BaseRevision {
		writeJSON(w, http.StatusConflict, current)
		return
	}

	next := TagsDocument{
		Revision:   current.Revision + 1,
		UpdatedAt:  time.Now().Unix(),
		Identities: req.Identities,
	}
	data, err := json.Marshal(next)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := s.tags.Save(WithDrive(ctx, files), data); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, putTagsResponse{Revision: next.Revision})
}
