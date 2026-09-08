package proton

import (
	"context"
	"io"

	"github.com/go-resty/resty/v2"
)

func (c *Client) GetBlock(ctx context.Context, bareURL, token string) (io.ReadCloser, error) {
	res, err := c.doRes(ctx, func(r *resty.Request) (*resty.Response, error) {
		return r.SetHeader("pm-storage-token", token).SetDoNotParseResponse(true).Get(bareURL)
	})
	if err != nil {
		return nil, err
	}

	return res.RawBody(), nil
}

func (c *Client) RequestBlockUpload(ctx context.Context, req BlockUploadReq) ([]BlockUploadLink, error) {
	links, _, err := c.RequestBlockAndThumbnailUpload(ctx, req)
	return links, err
}

// RequestBlockAndThumbnailUpload also returns upload links for any
// thumbnails named in req.ThumbnailList (added locally -- this fork only
// ever read UploadLinks). Photos uploaded without thumbnails appear in the
// Proton Photos timeline with no preview image at all, and there is no API
// to attach one after the revision is committed.
func (c *Client) RequestBlockAndThumbnailUpload(ctx context.Context, req BlockUploadReq) ([]BlockUploadLink, []ThumbnailUploadLink, error) {
	var res struct {
		UploadLinks    []BlockUploadLink
		ThumbnailLinks []ThumbnailUploadLink
	}

	if err := c.do(ctx, func(r *resty.Request) (*resty.Response, error) {
		return r.SetResult(&res).SetBody(req).Post("/drive/blocks")
	}); err != nil {
		return nil, nil, err
	}

	return res.UploadLinks, res.ThumbnailLinks, nil
}

func (c *Client) UploadBlock(ctx context.Context, bareURL, token string, block io.Reader) error {
	return c.do(ctx, func(r *resty.Request) (*resty.Response, error) {
		return r.
			SetHeader("pm-storage-token", token).
			SetMultipartField("Block", "blob", "application/octet-stream", block).
			Post(bareURL)
	})
}
