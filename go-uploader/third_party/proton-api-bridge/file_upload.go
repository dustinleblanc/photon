package proton_api_bridge

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"io"
	"mime"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/ProtonMail/gopenpgp/v2/crypto"
	"github.com/ProtonMail/go-proton-api"
)

func (protonDrive *ProtonDrive) handleRevisionConflict(ctx context.Context, link *proton.Link, createFileResp *proton.CreateFileRes) (string, bool, error) {
	if link != nil {
		linkID := link.LinkID

		draftRevision, err := protonDrive.GetRevisions(ctx, link, proton.RevisionStateDraft)
		if err != nil {
			return "", false, err
		}

		// if we have a draft revision, depending on the user config, we can abort the upload or recreate a draft
		// if we have no draft revision, then we can create a new draft revision directly (there is a restriction of 1 draft revision per file)
		if len(draftRevision) > 0 {
			// TODO: maintain clientUID to mark that this is our own draft (which can indicate failed upload attempt!)
			if protonDrive.Config.ReplaceExistingDraft {
				// Question: how do we observe for file upload cancellation -> clientUID?
				// Random thoughts: if there are concurrent modification to the draft, the server should be able to catch this when commiting the revision
				// since the manifestSignature (hash) will fail to match

				// delete the draft revision (will fail if the file only have a draft but no active revisions)
				if link.State == proton.LinkStateDraft {
					// delete the link (skipping trash, otherwise it won't work)
					err = protonDrive.c.DeleteChildren(ctx, protonDrive.MainShare.ShareID, link.ParentLinkID, linkID)
					if err != nil {
						return "", false, err
					}

					return "", true, nil
				}

				// delete the draft revision
				err = protonDrive.c.DeleteRevision(ctx, protonDrive.MainShare.ShareID, linkID, draftRevision[0].ID)
				if err != nil {
					return "", false, err
				}
			} else {
				// if there is a draft, based on the web behavior, it will ask if the user wants to replace the failed upload attempt
				// current behavior, we report an error to not upload the file (conservative)
				return "", false, ErrDraftExists
			}
		}

		// create a new revision
		newRevision, err := protonDrive.c.CreateRevision(ctx, protonDrive.MainShare.ShareID, linkID)
		if err != nil {
			return "", false, err
		}

		return newRevision.ID, false, nil
	} else if createFileResp != nil {
		return createFileResp.RevisionID, false, nil
	} else {
		// should not happen anymore, since the file search will include the draft now
		return "", false, ErrInternalErrorOnFileUpload
	}
}

func (protonDrive *ProtonDrive) createFileUploadDraft(ctx context.Context, parentLink *proton.Link, filename string, modTime time.Time, mimeType string) (string, string, *crypto.SessionKey, *crypto.KeyRing, []byte, error) {
	parentNodeKR, err := protonDrive.getLinkKR(ctx, parentLink)
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	/*
		Encryption: parent link's node key
		Signature: share's signature address keys
	*/
	newNodeKey, newNodePassphraseEnc, newNodePassphraseSignature, err := generateNodeKeys(parentNodeKR, protonDrive.DefaultAddrKR)
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	createFileReq := proton.CreateFileReq{
		ParentLinkID: parentLink.LinkID,

		// Name     string // Encrypted File Name
		// Hash     string // Encrypted File Name hash
		MIMEType: mimeType, // MIME Type

		// ContentKeyPacket          string // The block's key packet, encrypted with the node key.
		// ContentKeyPacketSignature string // Unencrypted signature of the content session key, signed with the NodeKey

		NodeKey:                 newNodeKey,                 // The private NodeKey, used to decrypt any file/folder content.
		NodePassphrase:          newNodePassphraseEnc,       // The passphrase used to unlock the NodeKey, encrypted by the owning Link/Share keyring.
		NodePassphraseSignature: newNodePassphraseSignature, // The signature of the NodePassphrase

		SignatureAddress: protonDrive.signatureAddress, // Signature email address used to sign passphrase and name
	}

	/*
		Encryption: parent link's node key
		Signature: share's signature address keys
	*/
	err = createFileReq.SetName(filename, protonDrive.DefaultAddrKR, parentNodeKR)
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	/*
		Encryption: parent link's node key
		Signature: parent link's node key
	*/
	signatureVerificationKR, err := protonDrive.getSignatureVerificationKeyring([]string{parentLink.SignatureEmail}, parentNodeKR)
	if err != nil {
		return "", "", nil, nil, nil, err
	}
	parentHashKey, err := parentLink.GetHashKey(parentNodeKR, signatureVerificationKR)
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	/* Use parent's hash key */
	err = createFileReq.SetHash(filename, parentHashKey)
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	/*
		Encryption: parent link's node key
		Signature: share's signature address keys
	*/
	newNodeKR, err := getKeyRing(parentNodeKR, protonDrive.DefaultAddrKR, newNodeKey, newNodePassphraseEnc, newNodePassphraseSignature)
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	/*
		Encryption: current link's node key
		Signature: share's signature address keys
	*/
	newSessionKey, err := createFileReq.SetContentKeyPacketAndSignature(newNodeKR)
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	createFileAction := func() (*proton.CreateFileRes, *proton.Link, error) {
		createFileResp, err := protonDrive.c.CreateFile(ctx, protonDrive.MainShare.ShareID, createFileReq)
		if err != nil {
			// FIXME: check for duplicated filename by relying on checkAvailableHashes -> able to retrieve linkID too
			// Also saving generating resources such as new nodeKR, etc.

			if err != proton.ErrFileNameExist {
				// other real error caught
				return nil, nil, err
			}

			// search for the link within this folder which has an active/draft revision as we have a file creation conflict
			link, err := protonDrive.SearchByNameInActiveFolder(ctx, parentLink, filename, true, false, proton.LinkStateActive)
			if err != nil {
				return nil, nil, err
			}

			if link == nil {
				link, err = protonDrive.SearchByNameInActiveFolder(ctx, parentLink, filename, true, false, proton.LinkStateDraft)
				if err != nil {
					return nil, nil, err
				}

				if link == nil {
					// we have a real problem here (unless the assumption is wrong)
					// since we can't create a new file AND we can't locate a file with active/draft revision in it
					return nil, nil, ErrCantLocateRevision
				}
			}

			return nil, link, nil
		}

		return &createFileResp, nil, nil
	}

	createFileResp, link, err := createFileAction()
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	revisionID, shouldSubmitCreateFileRequestAgain, err := protonDrive.handleRevisionConflict(ctx, link, createFileResp)
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	if shouldSubmitCreateFileRequestAgain {
		// the case where the link has only a draft but no active revision
		// we need to delete the link and recreate one
		createFileResp, link, err = createFileAction()
		if err != nil {
			return "", "", nil, nil, nil, err
		}

		revisionID, _, err = protonDrive.handleRevisionConflict(ctx, link, createFileResp)
		if err != nil {
			return "", "", nil, nil, nil, err
		}
	}

	linkID := ""
	if link != nil {
		linkID = link.LinkID

		// get original sessionKey and nodeKR for the current link
		parentNodeKR, err = protonDrive.getLinkKRByID(ctx, link.ParentLinkID)
		if err != nil {
			return "", "", nil, nil, nil, err
		}
		signatureVerificationKR, err := protonDrive.getSignatureVerificationKeyring([]string{link.SignatureEmail})
		if err != nil {
			return "", "", nil, nil, nil, err
		}
		newNodeKR, err = link.GetKeyRing(parentNodeKR, signatureVerificationKR)
		if err != nil {
			return "", "", nil, nil, nil, err
		}
		newSessionKey, err = link.GetSessionKey(newNodeKR)
		if err != nil {
			return "", "", nil, nil, nil, err
		}
	} else {
		linkID = createFileResp.ID
	}

	verificationData, err := protonDrive.c.GetRevisionVerificationData(ctx, protonDrive.MainShare.VolumeID, linkID, revisionID)
	if err != nil {
		return "", "", nil, nil, nil, err
	}
	verificationCode, err := base64.StdEncoding.DecodeString(verificationData.VerificationCode)
	if err != nil {
		return "", "", nil, nil, nil, err
	}

	return linkID, revisionID, newSessionKey, newNodeKR, verificationCode, nil
}

// Thumbnail is a rendered preview to attach to the revision. Photos
// uploaded without one show up in the Proton Photos timeline with no
// preview image, and there is no API to add one after the commit.
type Thumbnail struct {
	Type int // proton.ThumbnailTypeDefault / ThumbnailTypePhoto
	Data []byte
}

type encryptedThumbnail struct {
	thumbType int
	encData   []byte
	hash      []byte // raw sha256, for the manifest
	base64   string  // base64 sha256, for the request
}

// encryptThumbnails encrypts each thumbnail with the revision's content
// session key. Unlike content blocks (which carry a separate detached
// EncSignature field), the thumbnail request has no signature field, so the
// signature is embedded via EncryptAndSign -- matching Proton's own SDK
// (encryptThumbnailBlock takes the signing key and returns only encrypted
// data).
func (protonDrive *ProtonDrive) encryptThumbnails(sessionKey *crypto.SessionKey, thumbnails []Thumbnail) ([]encryptedThumbnail, error) {
	result := make([]encryptedThumbnail, 0, len(thumbnails))
	for _, thumbnail := range thumbnails {
		if len(thumbnail.Data) == 0 {
			continue
		}
		encData, err := sessionKey.EncryptAndSign(crypto.NewPlainMessage(thumbnail.Data), protonDrive.DefaultAddrKR)
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(encData)
		result = append(result, encryptedThumbnail{
			thumbType: thumbnail.Type,
			encData:   encData,
			hash:      sum[:],
			base64:    base64.StdEncoding.EncodeToString(sum[:]),
		})
	}
	// The manifest expects thumbnail hashes ordered by type.
	sort.Slice(result, func(i, j int) bool { return result[i].thumbType < result[j].thumbType })
	return result, nil
}

func (protonDrive *ProtonDrive) uploadAndCollectBlockData(ctx context.Context, newSessionKey *crypto.SessionKey, newNodeKR *crypto.KeyRing, verificationCode []byte, thumbnails []Thumbnail, file io.Reader, linkID, revisionID string) ([]byte, int64, []int64, string, error) {
	type PendingUploadBlocks struct {
		blockUploadInfo proton.BlockUploadInfo
		encData         []byte
	}

	if newSessionKey == nil || newNodeKR == nil {
		return nil, 0, nil, "", ErrMissingInputUploadAndCollectBlockData
	}

	totalFileSize := int64(0)

	encThumbnails, err := protonDrive.encryptThumbnails(newSessionKey, thumbnails)
	if err != nil {
		return nil, 0, nil, "", err
	}

	// Proton's SDK builds the manifest as thumbnail hashes (ordered by
	// type) followed by the content block hashes -- get this order wrong
	// and the commit's manifest signature fails to verify.
	manifestSignatureData := make([]byte, 0)
	for _, t := range encThumbnails {
		manifestSignatureData = append(manifestSignatureData, t.hash...)
	}

	// Thumbnails belong to the revision, not to any one page of blocks, so
	// they're requested and uploaded alongside the first batch only.
	thumbnailsPending := len(encThumbnails) > 0

	pendingUploadBlocks := make([]PendingUploadBlocks, 0)
	uploadPendingBlocks := func() error {
		if len(pendingUploadBlocks) == 0 && !thumbnailsPending {
			return nil
		}

		blockList := make([]proton.BlockUploadInfo, 0)
		for i := range pendingUploadBlocks {
			blockList = append(blockList, pendingUploadBlocks[i].blockUploadInfo)
		}
		blockUploadReq := proton.BlockUploadReq{
			AddressID:  protonDrive.MainShare.AddressID,
			ShareID:    protonDrive.MainShare.ShareID,
			LinkID:     linkID,
			RevisionID: revisionID,

			BlockList: blockList,
		}
		if thumbnailsPending {
			for _, t := range encThumbnails {
				blockUploadReq.ThumbnailList = append(blockUploadReq.ThumbnailList, proton.ThumbnailUploadInfo{
					Type: t.thumbType,
					Size: int64(len(t.encData)),
					Hash: t.base64,
				})
			}
		}

		blockUploadResp, thumbnailResp, err := protonDrive.c.RequestBlockAndThumbnailUpload(ctx, blockUploadReq)
		if err != nil {
			return err
		}

		errChan := make(chan error)
		pendingUploads := 0

		uploadBlockWrapper := func(ctx context.Context, errChan chan error, bareURL, token string, block io.Reader) {
			if err := protonDrive.blockUploadSemaphore.Acquire(ctx, 1); err != nil {
				errChan <- err
				return
			}
			defer protonDrive.blockUploadSemaphore.Release(1)

			errChan <- protonDrive.c.UploadBlock(ctx, bareURL, token, block)
		}

		for i := range blockUploadResp {
			go uploadBlockWrapper(ctx, errChan, blockUploadResp[i].BareURL, blockUploadResp[i].Token, bytes.NewReader(pendingUploadBlocks[i].encData))
			pendingUploads++
		}

		if thumbnailsPending {
			for _, link := range thumbnailResp {
				var data []byte
				for _, t := range encThumbnails {
					if t.thumbType == link.ThumbnailType {
						data = t.encData
						break
					}
				}
				if data == nil {
					continue
				}
				go uploadBlockWrapper(ctx, errChan, link.BareURL, link.Token, bytes.NewReader(data))
				pendingUploads++
			}
			thumbnailsPending = false
		}

		var firstErr error
		for i := 0; i < pendingUploads; i++ {
			if err := <-errChan; err != nil && firstErr == nil {
				firstErr = err
			}
		}
		if firstErr != nil {
			return firstErr
		}

		pendingUploadBlocks = pendingUploadBlocks[:0]

		return nil
	}

	shouldContinue := true
	sha1Digests := sha1.New()
	blockSizes := make([]int64, 0)
	for i := 1; shouldContinue; i++ {
		if (i-1) > 0 && (i-1)%UPLOAD_BATCH_BLOCK_SIZE == 0 {
			err := uploadPendingBlocks()
			if err != nil {
				return nil, 0, nil, "", err
			}
		}

		// read at most data of size UPLOAD_BLOCK_SIZE
		// for some reason, .Read might not actually read up to buffer size -> use io.ReadFull
		data := make([]byte, UPLOAD_BLOCK_SIZE) // FIXME: get block size from the server config instead of hardcoding it
		readBytes, err := io.ReadFull(file, data)
		if err != nil {
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				// might still have data to read!
				if readBytes == 0 {
					break
				}
				shouldContinue = false
			} else {
				// all other errors
				return nil, 0, nil, "", err
			}
		}
		data = data[:readBytes]
		totalFileSize += int64(readBytes)
		sha1Digests.Write(data)
		blockSizes = append(blockSizes, int64(readBytes))

		// encrypt block data
		/*
			Encryption: current link's session key
			Signature: share's signature address keys
		*/
		dataPlainMessage := crypto.NewPlainMessage(data)
		encData, err := newSessionKey.Encrypt(dataPlainMessage)
		if err != nil {
			return nil, 0, nil, "", err
		}

		encSignature, err := protonDrive.DefaultAddrKR.SignDetachedEncrypted(dataPlainMessage, newNodeKR)
		if err != nil {
			return nil, 0, nil, "", err
		}
		encSignatureStr, err := encSignature.GetArmored()
		if err != nil {
			return nil, 0, nil, "", err
		}

		h := sha256.New()
		h.Write(encData)
		hash := h.Sum(nil)
		base64Hash := base64.StdEncoding.EncodeToString(hash)
		if err != nil {
			return nil, 0, nil, "", err
		}
		manifestSignatureData = append(manifestSignatureData, hash...)

		pendingUploadBlocks = append(pendingUploadBlocks, PendingUploadBlocks{
			blockUploadInfo: proton.BlockUploadInfo{
				Index:        i, // iOS drive: BE starts with 1
				Size:         int64(len(encData)),
				EncSignature: encSignatureStr,
				Hash:         base64Hash,
				Verifier: proton.BlockVerifier{
					Token: proton.BuildVerificationToken(verificationCode, encData),
				},
			},
			encData: encData,
		})
	}
	if err := uploadPendingBlocks(); err != nil {
		return nil, 0, nil, "", err
	}

	sha1Hash := sha1Digests.Sum(nil)
	sha1String := hex.EncodeToString(sha1Hash)
	return manifestSignatureData, totalFileSize, blockSizes, sha1String, nil
}

func (protonDrive *ProtonDrive) commitNewRevision(ctx context.Context, nodeKR *crypto.KeyRing, xAttrCommon *proton.RevisionXAttrCommon, camera *proton.RevisionXAttrCamera, photo *proton.CommitRevisionPhoto, manifestSignatureData []byte, linkID, revisionID string) error {
	manifestSignature, err := protonDrive.DefaultAddrKR.SignDetached(crypto.NewPlainMessage(manifestSignatureData))
	if err != nil {
		return err
	}
	manifestSignatureString, err := manifestSignature.GetArmored()
	if err != nil {
		return err
	}

	commitRevisionReq := proton.CommitRevisionReq{
		ManifestSignature: manifestSignatureString,
		SignatureAddress:  protonDrive.signatureAddress,
		Photo:             photo,
	}

	err = commitRevisionReq.SetEncXAttrString(protonDrive.DefaultAddrKR, nodeKR, xAttrCommon, camera)
	if err != nil {
		return err
	}

	err = protonDrive.c.CommitRevision(ctx, protonDrive.MainShare.ShareID, linkID, revisionID, commitRevisionReq)
	if err != nil {
		return err
	}

	return nil
}

// testParam is for integration test only
// 0 = normal mode
// 1 = up to create revision
// 2 = up to block upload
func (protonDrive *ProtonDrive) uploadFile(ctx context.Context, parentLink *proton.Link, filename string, modTime time.Time, file io.Reader, thumbnails []Thumbnail, testParam int) (string, *proton.RevisionXAttrCommon, error) {
	// TODO: if we should use github.com/gabriel-vasile/mimetype to detect the MIME type from the file content itself
	// Note: this approach might cause the upload progress to display the "fake" progress, since we read in all the content all-at-once
	// mimetype.SetLimit(0)
	// mType := mimetype.Detect(fileContent)
	// mimeType := mType.String()

	// detect MIME type by looking at the filename only
	mimeType := mime.TypeByExtension(filepath.Ext(filename))
	if mimeType == "" {
		// api requires a mime type passed in
		mimeType = "text/plain"
	}

	/* step 1: create a draft */
	linkID, revisionID, newSessionKey, newNodeKR, verificationCode, err := protonDrive.createFileUploadDraft(ctx, parentLink, filename, modTime, mimeType)
	if err != nil {
		return "", nil, err
	}

	if testParam == 1 {
		return "", nil, nil
	}

	/* step 2: upload blocks and collect block data */
	manifestSignature, fileSize, blockSizes, digests, err := protonDrive.uploadAndCollectBlockData(ctx, newSessionKey, newNodeKR, verificationCode, thumbnails, file, linkID, revisionID)
	if err != nil {
		return "", nil, err
	}

	if testParam == 2 {
		// for integration tests
		// we try to simulate blocks uploaded but not yet commited
		return "", nil, nil
	}

	/* step 3: mark the file as active by commiting the revision */
	xAttrCommon := &proton.RevisionXAttrCommon{
		ModificationTime: modTime.Format("2006-01-02T15:04:05-0700"), /* ISO8601 */
		Size:             fileSize,
		BlockSizes:       blockSizes,
		Digests: map[string]string{
			"SHA1": digests,
		},
	}
	// Photos-share revisions are rejected (Code=2511) without at least
	// Camera.CaptureTime set. We don't do EXIF parsing here, so fall back
	// to the file's modification time -- the same fallback Proton's own
	// SDK uses when a photo has no EXIF capture time.
	camera := &proton.RevisionXAttrCamera{
		CaptureTime: modTime.UTC().Format("2006-01-02T15:04:05.000Z"),
	}

	// The commit itself additionally requires a PLAINTEXT top-level Photo
	// field (separate from the encrypted XAttr/Camera above -- the server
	// can't decrypt XAttr, so it needs an unencrypted CaptureTime +
	// ContentHash to validate/index the photo). Confirmed from Proton's
	// own official Drive SDK (CommitRevisionPhotoDto).
	parentNodeKRForHash, err := protonDrive.getLinkKR(ctx, parentLink)
	if err != nil {
		return "", nil, err
	}
	sigVerifyKRForHash, err := protonDrive.getSignatureVerificationKeyring([]string{parentLink.SignatureEmail}, parentNodeKRForHash)
	if err != nil {
		return "", nil, err
	}
	parentHashKey, err := parentLink.GetHashKey(parentNodeKRForHash, sigVerifyKRForHash)
	if err != nil {
		return "", nil, err
	}
	photo := &proton.CommitRevisionPhoto{
		CaptureTime: modTime.UTC().Unix(),
		ContentHash: proton.ComputePhotoContentHash(parentHashKey, digests),
	}

	err = protonDrive.commitNewRevision(ctx, newNodeKR, xAttrCommon, camera, photo, manifestSignature, linkID, revisionID)
	if err != nil {
		return "", nil, err
	}

	return linkID, xAttrCommon, nil
}

func (protonDrive *ProtonDrive) UploadFileByReader(ctx context.Context, parentLinkID string, filename string, modTime time.Time, file io.Reader, testParam int) (string, *proton.RevisionXAttrCommon, error) {
	parentLink, err := protonDrive.getLink(ctx, parentLinkID)
	if err != nil {
		return "", nil, err
	}

	return protonDrive.uploadFile(ctx, parentLink, filename, modTime, file, nil, testParam)
}

// UploadFileByReaderWithThumbnails is UploadFileByReader plus rendered
// previews. Added locally: photos need thumbnails attached during the
// block-upload phase, and there is no API to add them after the commit.
func (protonDrive *ProtonDrive) UploadFileByReaderWithThumbnails(ctx context.Context, parentLinkID string, filename string, modTime time.Time, file io.Reader, thumbnails []Thumbnail) (string, *proton.RevisionXAttrCommon, error) {
	parentLink, err := protonDrive.getLink(ctx, parentLinkID)
	if err != nil {
		return "", nil, err
	}

	return protonDrive.uploadFile(ctx, parentLink, filename, modTime, file, thumbnails, 0)
}

func (protonDrive *ProtonDrive) UploadFileByPath(ctx context.Context, parentLink *proton.Link, filename string, filePath string, testParam int) (string, *proton.RevisionXAttrCommon, error) {
	f, err := os.Open(filePath)
	if err != nil {
		return "", nil, err
	}
	defer f.Close()

	info, err := os.Stat(filePath)
	if err != nil {
		return "", nil, err
	}

	in := bufio.NewReader(f)

	return protonDrive.uploadFile(ctx, parentLink, filename, info.ModTime(), in, nil, testParam)
}

/*
There is a route that proton-go-api doesn't have - checkAvailableHashes.
This is used to quickly find the next available filename when the originally supplied filename is taken in the current folder.

Based on the code below, which is taken from the Proton iOS Drive app, we can infer that:
- when a file is to be uploaded && there is filename conflict after the first upload:
	- on web, user will be prompted with a) overwrite b) keep both by appending filename with iteration number c) do nothing
- on the iOS client logic, we can see that when the filename conflict happens (after the upload attampt failed)
	- the filename will be hashed by using filename + iteration
	- 10 iterations will be done per batch, each iteration's hash will be sent to the server
	- the server will return available hashes, and the client will take the lowest iteration as the filename to be used
	- will be used to search for the next available filename (using hashes avoids the filename being known to the server)
*/
