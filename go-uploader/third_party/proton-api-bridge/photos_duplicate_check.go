package proton_api_bridge

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/ProtonMail/go-proton-api"
)

// DuplicateMatch is an existing photo whose *name* hashes to the same value
// as the one being uploaded. A name match alone does not mean it is the
// same photo -- camera filenames like DSC01107.JPG collide constantly
// across devices and counter rollovers -- so callers must compare
// ContentHash before deciding to skip anything.
type DuplicateMatch struct {
	LinkID      string
	ContentHash string
}

const linkStateTrashed = 2

// parentHashKey returns the Photos share root's hash key, which is what
// both name hashes and photo content hashes are keyed with.
func (protonDrive *ProtonDrive) parentHashKey(ctx context.Context) ([]byte, error) {
	parentNodeKR, err := protonDrive.getLinkKR(ctx, protonDrive.RootLink)
	if err != nil {
		return nil, err
	}
	signatureVerificationKR, err := protonDrive.getSignatureVerificationKeyring([]string{protonDrive.RootLink.SignatureEmail}, parentNodeKR)
	if err != nil {
		return nil, err
	}
	return protonDrive.RootLink.GetHashKey(parentNodeKR, signatureVerificationKR)
}

// FindDuplicatesByName asks Proton which existing photos share this
// filename (POST /drive/volumes/{volumeID}/photos/duplicates), the same
// check Proton's own clients run before uploading. Trashed links are
// ignored -- their name is free to reuse.
func (protonDrive *ProtonDrive) FindDuplicatesByName(ctx context.Context, filename string) ([]DuplicateMatch, error) {
	hashKey, err := protonDrive.parentHashKey(ctx)
	if err != nil {
		return nil, err
	}

	nameHash, err := proton.GetNameHash(filename, hashKey)
	if err != nil {
		return nil, err
	}

	duplicates, err := protonDrive.c.FindPhotoDuplicates(ctx, protonDrive.MainShare.VolumeID, []string{nameHash})
	if err != nil {
		return nil, err
	}

	var matches []DuplicateMatch
	for _, d := range duplicates {
		if d.Hash == nameHash && d.LinkState != linkStateTrashed {
			matches = append(matches, DuplicateMatch{LinkID: d.LinkID, ContentHash: d.ContentHash})
		}
	}
	return matches, nil
}

// FindAvailableName returns the first free "name (n).ext" for a filename
// whose name is already taken by a different photo.
//
// Candidates are checked in batches because the duplicates endpoint takes a
// list of hashes: probing one at a time cost one round-trip per candidate,
// which for a name already at "(97)" meant ~96 sequential requests for a
// single photo. This is the approach Proton's own client documents --
// hash a batch of iterations, ask once, take the lowest free one.
// isReserved lets a concurrent caller exclude names it has already handed
// to another in-flight upload but which the server does not know about yet.
// Pass nil when uploading serially.
func (protonDrive *ProtonDrive) FindAvailableName(ctx context.Context, filename string, isReserved func(string) bool) (string, error) {
	hashKey, err := protonDrive.parentHashKey(ctx)
	if err != nil {
		return "", err
	}

	ext := filepath.Ext(filename)
	base := strings.TrimSuffix(filename, ext)

	const (
		batchSize = 20
		maxTries  = 10000 // generous: some names (icon.png, image000000.jpg) repeat a lot
	)

	for start := 2; start < maxTries; start += batchSize {
		candidates := make([]string, 0, batchSize)
		hashes := make([]string, 0, batchSize)

		for n := start; n < start+batchSize; n++ {
			candidate := fmt.Sprintf("%s (%d)%s", base, n, ext)
			hash, err := proton.GetNameHash(candidate, hashKey)
			if err != nil {
				return "", err
			}
			candidates = append(candidates, candidate)
			hashes = append(hashes, hash)
		}

		duplicates, err := protonDrive.c.FindPhotoDuplicates(ctx, protonDrive.MainShare.VolumeID, hashes)
		if err != nil {
			return "", err
		}

		taken := make(map[string]bool, len(duplicates))
		for _, d := range duplicates {
			if d.LinkState != linkStateTrashed {
				taken[d.Hash] = true
			}
		}

		for i, hash := range hashes {
			if taken[hash] {
				continue
			}
			if isReserved != nil && isReserved(candidates[i]) {
				continue
			}
			return candidates[i], nil
		}
	}

	return "", fmt.Errorf("no free filename for %s after %d attempts", filename, maxTries)
}

// PhotoContentHash computes the same content hash Proton stores for a
// photo, from the SHA1 of its plaintext contents:
// lower_hex(hmacSha256(parent hash key, lower_hex(sha1(content)))).
// Comparing this against a DuplicateMatch's ContentHash is what
// distinguishes "already uploaded" from "different photo, same filename".
func (protonDrive *ProtonDrive) PhotoContentHash(ctx context.Context, sha1HexOfContent string) (string, error) {
	hashKey, err := protonDrive.parentHashKey(ctx)
	if err != nil {
		return "", err
	}
	return proton.ComputePhotoContentHash(hashKey, sha1HexOfContent), nil
}
