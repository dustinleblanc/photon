package proton

import (
	"context"
	"fmt"

	"github.com/go-resty/resty/v2"
)

// Added locally: this fork predates the server's block-verification
// requirement. Confirmed from Proton's own official Drive SDK
// (client/js/src/internal/upload/apiService.ts getVerificationData):
// GET /drive/v2/volumes/{volumeID}/links/{linkID}/revisions/{revisionID}/verification
// returns the VerificationCode to use for this specific draft revision --
// it is NOT something the client can derive locally from its own content
// key packet (that only works for a distinct "small file" one-shot upload
// path this project doesn't use).
type RevisionVerificationData struct {
	VerificationCode string // base64
	ContentKeyPacket string // base64
}

func (c *Client) GetRevisionVerificationData(ctx context.Context, volumeID, linkID, revisionID string) (RevisionVerificationData, error) {
	var res RevisionVerificationData

	if err := c.do(ctx, func(r *resty.Request) (*resty.Response, error) {
		path := fmt.Sprintf("/drive/v2/volumes/%s/links/%s/revisions/%s/verification", volumeID, linkID, revisionID)
		return r.SetResult(&res).Get(path)
	}); err != nil {
		return RevisionVerificationData{}, err
	}

	return res, nil
}
