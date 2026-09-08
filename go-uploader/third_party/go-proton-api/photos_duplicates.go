package proton

import (
	"context"

	"github.com/go-resty/resty/v2"
)

// Added locally: this fork predates dedup support. Confirmed from Proton's
// own open-sourced iOS client (FindDuplicatesEndpoint.swift):
// POST /drive/volumes/{volumeID}/photos/duplicates with {"NameHashes": [...]}.
type PhotoDuplicate struct {
	Hash        string
	ContentHash string
	LinkState   int // 0=draft, 1=active, 2=trashed
	ClientUID   string
	LinkID      string
}

type findPhotoDuplicatesResponse struct {
	DuplicateHashes []PhotoDuplicate
}

func (c *Client) FindPhotoDuplicates(ctx context.Context, volumeID string, nameHashes []string) ([]PhotoDuplicate, error) {
	var res findPhotoDuplicatesResponse

	body := struct {
		NameHashes []string
	}{NameHashes: nameHashes}

	if err := c.do(ctx, func(r *resty.Request) (*resty.Response, error) {
		return r.SetBody(body).SetResult(&res).Post("/drive/volumes/" + volumeID + "/photos/duplicates")
	}); err != nil {
		return nil, err
	}

	return res.DuplicateHashes, nil
}
