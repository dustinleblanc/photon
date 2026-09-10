package asset

// Record mirrors the JSON emitted by `photos-helper list`, one object per line.
type Record struct {
	LocalIdentifier  string  `json:"localIdentifier"`
	MediaType        int     `json:"mediaType"`
	MediaSubtypes    int     `json:"mediaSubtypes"`
	CreationDate     float64 `json:"creationDate"`
	ModificationDate float64 `json:"modificationDate"`
	PixelWidth       int     `json:"pixelWidth"`
	PixelHeight      int     `json:"pixelHeight"`
	HasAdjustments   bool    `json:"hasAdjustments"`
	IsFavorite       bool    `json:"isFavorite"`
	Duration         float64 `json:"duration"`
	OriginalFilename string  `json:"originalFilename"`
	ResourceTypes    []int   `json:"resourceTypes"`
}

// Version distinguishes the two possible uploads for a single PHAsset.
type Version string

const (
	VersionOriginal Version = "original"
	VersionEdited   Version = "edited"
)
