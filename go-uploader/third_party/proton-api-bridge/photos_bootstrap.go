package proton_api_bridge

import (
	"context"
	"errors"

	"github.com/henrybear327/Proton-API-Bridge/common"
	"golang.org/x/sync/semaphore"

	"github.com/ProtonMail/go-proton-api"
)

var ErrNoActivePhotosShare = errors.New("no active Photos share found on this account")

// NewProtonDriveForPhotos bootstraps a *ProtonDrive scoped to the account's
// Photos share/volume instead of the regular Drive main share. Every other
// ProtonDrive method (UploadFileByReader, etc.) works unmodified against
// whichever share MainShare/MainShareKR/RootLink point at -- Photos storage
// is structurally just regular encrypted files living in a differently
// typed share, uploaded through the exact same "/shares/{id}/files"
// endpoint (confirmed from Proton's own iOS client source), so no changes
// to the upload logic itself are needed, only which share gets bootstrapped
// as "main" here.
func NewProtonDriveForPhotos(ctx context.Context, config *common.Config, authHandler proton.AuthHandler, deAuthHandler proton.Handler) (*ProtonDrive, *common.ProtonDriveCredential, error) {
	m, c, credentials, userKR, addrKRs, addrData, err := common.Login(ctx, config, authHandler, deAuthHandler)
	if err != nil {
		return nil, nil, err
	}

	shares, err := getAllShares(ctx, c)
	if err != nil {
		return nil, nil, err
	}

	var photosShareID string
	for i := range shares {
		if shares[i].Type == proton.ShareTypePhotos && shares[i].State == proton.ShareStateActive && !shares[i].Locked {
			photosShareID = shares[i].ShareID
			break
		}
	}
	if photosShareID == "" {
		return nil, nil, ErrNoActivePhotosShare
	}

	photosShare, err := getShareByID(ctx, c, photosShareID)
	if err != nil {
		return nil, nil, err
	}

	rootLink, err := c.GetLink(ctx, photosShare.ShareID, photosShare.LinkID)
	if err != nil {
		return nil, nil, err
	}

	photosShareAddrKR := addrKRs[photosShare.AddressID]
	photosShareKR, err := photosShare.GetKeyRing(photosShareAddrKR)
	if err != nil {
		return nil, nil, err
	}

	return &ProtonDrive{
		MainShare: photosShare,
		RootLink:  &rootLink,

		MainShareKR:   photosShareKR,
		DefaultAddrKR: photosShareAddrKR,

		Config: config,

		c:                c,
		m:                m,
		userKR:           userKR,
		addrKRs:          addrKRs,
		addrData:         addrData,
		signatureAddress: photosShare.Creator,

		cache:                newCache(config.EnableCaching),
		blockUploadSemaphore: semaphore.NewWeighted(int64(config.ConcurrentBlockUploadCount)),
		blockCryptoSemaphore: semaphore.NewWeighted(int64(config.ConcurrentFileCryptoCount)),
	}, credentials, nil
}

// ListPhotos pages the Photos volume's timeline. Exposed here so callers
// can reconcile against what is already uploaded without needing a second,
// separately-authenticated client of their own.
func (protonDrive *ProtonDrive) ListPhotos(ctx context.Context, lastID string, pageSize int) ([]proton.PhotosListResponsePhoto, error) {
	return protonDrive.c.ListPhotos(ctx, protonDrive.MainShare.VolumeID, lastID, pageSize)
}
