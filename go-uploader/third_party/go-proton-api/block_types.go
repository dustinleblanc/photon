package proton

// Block is a block of file contents. They are split in 4MB blocks although this number may change in the future.
// Each block is its own data packet separated from the key packet which is held by the node,
// which means the sessionKey is the same for every block.
type Block struct {
	Index int

	BareURL string // URL to the block
	Token   string // Token for download URL

	Hash           string // Encrypted block's sha256 hash, in base64
	EncSignature   string // Encrypted signature of the block
	SignatureEmail string // Email used to sign the block
}

type BlockUploadReq struct {
	AddressID  string
	ShareID    string
	LinkID     string
	RevisionID string

	BlockList []BlockUploadInfo

	// ThumbnailList is omitted when empty so non-photo uploads keep the
	// exact request shape this fork sent before.
	ThumbnailList []ThumbnailUploadInfo `json:",omitempty"`
}

// Thumbnail types, per Proton's own Mac client (PDCore Constants.swift):
//
//	Type 1: "default"    -- max 512x512,   max 60KB
//	Type 2: "photo" (HD) -- max 1920x1920, max 1MB
const (
	ThumbnailTypeDefault = 1
	ThumbnailTypePhoto   = 2
)

type ThumbnailUploadInfo struct {
	Type int
	Size int64
	Hash string // base64 sha256 of the encrypted thumbnail
}

type ThumbnailUploadLink struct {
	Token         string
	BareURL       string
	ThumbnailType int
}

type BlockUploadInfo struct {
	Index        int
	Size         int64
	EncSignature string
	Hash         string

	// Verifier is required by the current /drive/blocks endpoint (added
	// locally -- this fork predates it). Its absence is what the server's
	// generic "outdated app" error (Code=2000) actually meant: the request
	// shape itself is stale, not the App-Version string. See
	// BuildVerificationToken for how Token is computed.
	Verifier BlockVerifier
}

type BlockVerifier struct {
	Token string // base64-encoded verification token
}

type BlockUploadLink struct {
	Token   string
	BareURL string
}
