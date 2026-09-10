// Package core is the platform-agnostic domain for the Photon Library app.
//
// It owns the Proton Photos access, the catalog, and the HTTP seam the UI
// talks to. Platform-specific capabilities (HEIC decode, face detection) are
// expressed as interfaces here and implemented by per-OS adapters, so the
// core itself stays cgo-free and compiles for every target.
//
// Layout within this package:
//   - ports.go   the interfaces + domain types the rest of the core builds on
//   - client.go  the concrete Proton client (wraps the reverse-engineered bridge)
//   - server.go  the loopback HTTP API the Flutter UI consumes
package core

import (
	"context"
	"errors"
	"io"
)

// ErrPreviewUnavailable is returned by ProtonClient.FetchPreview when a preview
// cannot be produced yet. For M0 previews are not implemented (the bridge can
// upload thumbnails but has no download path); the grid is expected to fall back
// to on-demand originals or a placeholder until thumbnail fetch lands.
var ErrPreviewUnavailable = errors.New("preview unavailable")

// Photo is one item in the Proton Photos timeline. It maps 1:1 onto the
// reverse-engineered photos list, with the encrypted fields the UI may need.
type Photo struct {
	LinkID        string  `json:"linkId"`
	CaptureTime   int64   `json:"captureTime"`
	AddedTime     *int64  `json:"addedTime,omitempty"`
	Hash          string  `json:"hash"`
	ContentHash   string  `json:"contentHash"`
	Tags          []int   `json:"tags,omitempty"`
	RelatedPhotos []Photo `json:"relatedPhotos,omitempty"`
}

// ProtonClient abstracts access to the Proton Photos share so the
// reverse-engineered implementation can be swapped without touching the rest
// of the core. ListPhotos uses the timeline's "previous page last link id" as
// the cursor: an empty cursor returns the first page, and the caller advances
// by passing the last photo's LinkID.
type ProtonClient interface {
	ListPhotos(ctx context.Context, cursor string, pageSize int) ([]Photo, error)
	OpenOriginal(ctx context.Context, linkID string) (io.ReadCloser, int64, error)
	FetchPreview(ctx context.Context, linkID string, size int) ([]byte, error)
}

// ImageCodec decodes/encodes images where the platform is the only thing that
// understands the format (notably HEIC/AVIF). The pure-Go paths (JPEG/PNG,
// resizing) live in the core and don't need this.
type ImageCodec interface {
	Decode(r io.Reader) (Image, error)
	Encode(w io.Writer, img Image, format ImageFormat, quality int) error
	// Fit returns a scaled copy bounded by maxPx on the long edge.
	Fit(src []byte, maxPx int) ([]byte, error)
}

// Image is a decoded, raster image the core can pass between codec adapters
// and the export pipeline. It is deliberately minimal.
type Image interface {
	Bounds() (width, height int)
}

// ImageFormat is an output format for the export pipeline.
type ImageFormat string

const (
	FormatJPEG ImageFormat = "jpeg"
	FormatPNG  ImageFormat = "png"
	FormatWebP ImageFormat = "webp"
)

// Face is a detected face with a bounding box (normalized 0..1) and an
// embedding vector for clustering. Embeddings are engine-specific (Apple
// Vision vs ML Kit vs ONNX), which is why cross-device people matching is a
// deferred concern.
type Face struct {
	X, Y, W, H float64   // normalized to the image (0..1)
	Embedding  []float32 // engine-specific embedding vector
}

// FaceEngine detects faces and emits embeddings. Clustering and naming live
// in the core's people service, not here.
type FaceEngine interface {
	Detect(ctx context.Context, img Image) ([]Face, error)
}
