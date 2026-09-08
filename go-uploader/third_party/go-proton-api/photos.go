package proton

import (
	"context"
	"strconv"

	"github.com/go-resty/resty/v2"
)

// Added locally for photon-migrate: upstream go-proton-api doesn't wrap the
// Drive Photos endpoints, only generic Drive volumes/shares/links.

// ShareTypePhotos is not defined in the upstream ShareType enum (which only
// has Main/Standard/Device) but the backend does return it -- confirmed by
// reading Proton's own open-sourced iOS client (ListSharesEndpoint.swift).
const ShareTypePhotos ShareType = 4

type PhotosListResponsePhoto struct {
	LinkID        string
	CaptureTime   int64
	AddedTime     *int64
	Hash          string
	ContentHash   string
	Tags          []int
	RelatedPhotos []PhotosListResponsePhoto
}

func (c *Client) ListPhotos(ctx context.Context, volumeID string, lastID string, pageSize int) ([]PhotosListResponsePhoto, error) {
	var res struct {
		Photos []PhotosListResponsePhoto
		Code   int
	}

	if err := c.do(ctx, func(r *resty.Request) (*resty.Response, error) {
		req := r.SetResult(&res).SetQueryParam("PageSize", strconv.Itoa(pageSize))
		if lastID != "" {
			req = req.SetQueryParam("PreviousPageLastLinkID", lastID)
		}
		return req.Get("/drive/volumes/" + volumeID + "/photos")
	}); err != nil {
		return nil, err
	}

	return res.Photos, nil
}
