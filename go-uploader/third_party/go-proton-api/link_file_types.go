package proton

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"

	"github.com/ProtonMail/gopenpgp/v2/crypto"
)

/* Helper function */
func getEncryptedName(name string, addrKR, nodeKR *crypto.KeyRing) (string, error) {
	clearTextName := crypto.NewPlainMessageFromString(name)

	encName, err := nodeKR.Encrypt(clearTextName, addrKR)
	if err != nil {
		return "", err
	}

	encNameString, err := encName.GetArmored()
	if err != nil {
		return "", err
	}

	return encNameString, nil
}

func GetNameHash(name string, hashKey []byte) (string, error) {
	mac := hmac.New(sha256.New, hashKey)
	_, err := mac.Write([]byte(name))
	if err != nil {
		return "", err
	}

	return hex.EncodeToString(mac.Sum(nil)), nil
}

type MoveLinkReq struct {
	ParentLinkID string

	Name                    string // Encrypted File Name
	OriginalHash            string // Old Encrypted File Name Hash
	Hash                    string // Encrypted File Name Hash by using parent's NodeHashKey
	NodePassphrase          string // The passphrase used to unlock the NodeKey, encrypted by the owning Link/Share keyring.
	NodePassphraseSignature string // The signature of the NodePassphrase

	SignatureAddress string // Signature email address used to sign passphrase and name
}

func (moveLinkReq *MoveLinkReq) SetName(name string, addrKR, nodeKR *crypto.KeyRing) error {
	encNameString, err := getEncryptedName(name, addrKR, nodeKR)
	if err != nil {
		return err
	}

	moveLinkReq.Name = encNameString
	return nil
}

func (moveLinkReq *MoveLinkReq) SetHash(name string, hashKey []byte) error {
	nameHash, err := GetNameHash(name, hashKey)
	if err != nil {
		return err
	}

	moveLinkReq.Hash = nameHash
	return nil
}

type CreateFileReq struct {
	ParentLinkID string

	Name     string // Encrypted File Name
	Hash     string // Encrypted File Name Hash
	MIMEType string // MIME Type

	ContentKeyPacket          string // The block's key packet, encrypted with the node key.
	ContentKeyPacketSignature string // Unencrypted signature of the content session key, signed with the NodeKey

	NodeKey                 string // The private NodeKey, used to decrypt any file/folder content.
	NodePassphrase          string // The passphrase used to unlock the NodeKey, encrypted by the owning Link/Share keyring.
	NodePassphraseSignature string // The signature of the NodePassphrase

	SignatureAddress string // Signature email address used to sign passphrase and name
}

func (createFileReq *CreateFileReq) SetName(name string, addrKR, nodeKR *crypto.KeyRing) error {
	encNameString, err := getEncryptedName(name, addrKR, nodeKR)
	if err != nil {
		return err
	}

	createFileReq.Name = encNameString
	return nil
}

func (createFileReq *CreateFileReq) SetHash(name string, hashKey []byte) error {
	nameHash, err := GetNameHash(name, hashKey)
	if err != nil {
		return err
	}

	createFileReq.Hash = nameHash

	return nil
}

func (createFileReq *CreateFileReq) SetContentKeyPacketAndSignature(kr *crypto.KeyRing) (*crypto.SessionKey, error) {
	newSessionKey, err := crypto.GenerateSessionKey()
	if err != nil {
		return nil, err
	}

	encSessionKey, err := kr.EncryptSessionKey(newSessionKey)
	if err != nil {
		return nil, err
	}

	sessionKeyPlainMessage := crypto.NewPlainMessage(newSessionKey.Key)
	sessionKeySignature, err := kr.SignDetached(sessionKeyPlainMessage)
	if err != nil {
		return nil, err
	}
	armoredSessionKeySignature, err := sessionKeySignature.GetArmored()
	if err != nil {
		return nil, err
	}

	createFileReq.ContentKeyPacket = base64.StdEncoding.EncodeToString(encSessionKey)
	createFileReq.ContentKeyPacketSignature = armoredSessionKeySignature
	return newSessionKey, nil
}

type CreateFileRes struct {
	ID         string // Encrypted Link ID
	RevisionID string // Encrypted Revision ID
}

type CreateRevisionRes struct {
	ID string // Encrypted Revision ID
}

type CommitRevisionReq struct {
	ManifestSignature string
	SignatureAddress  string
	XAttr             string

	// Photo is required (added locally -- this fork predates it) when
	// committing a revision in a Photos-type share. Confirmed from
	// Proton's own official Drive SDK (CommitRevisionDto/
	// CommitRevisionPhotoDto in the generated API types): unlike XAttr,
	// this is a PLAINTEXT field -- the server can't read inside the
	// encrypted XAttr, so it needs CaptureTime/ContentHash unencrypted to
	// validate and index the photo.
	Photo *CommitRevisionPhoto `json:",omitempty"`
}

type CommitRevisionPhoto struct {
	// CaptureTime is Unix seconds (not ISO8601, unlike the XAttr Camera
	// field -- confirmed from the schema doc: "Photo capture timestamp (in
	// seconds), use negative values for times before 1970").
	CaptureTime int64

	// ContentHash: lower_hex(hmacSha256(parent folder hash key,
	// lower_hex(sha1(plain content)))) -- confirmed from the schema doc.
	ContentHash string
}

// ComputePhotoContentHash implements the ContentHash formula from
// CommitRevisionPhotoDto's schema doc: HMAC-SHA256 keyed with the parent
// folder's hash key (the same key used for filename hashing), over the
// ASCII hex string of the plaintext content's SHA1 -- not over the raw
// SHA1 bytes.
func ComputePhotoContentHash(parentHashKey []byte, sha1HexOfPlainContent string) string {
	mac := hmac.New(sha256.New, parentHashKey)
	mac.Write([]byte(sha1HexOfPlainContent))
	return hex.EncodeToString(mac.Sum(nil))
}

type RevisionXAttrCommon struct {
	ModificationTime string
	Size             int64
	BlockSizes       []int64
	Digests          map[string]string
}

// RevisionXAttrCamera carries the metadata a Photos-share revision commit
// requires (added locally -- this fork predates the requirement). Confirmed
// from Proton's own official Drive SDK
// (client/js/src/internal/nodes/extendedAttributes.ts): without at least
// CaptureTime set, the server rejects the commit with "Cannot commit
// Revision in Photo Share without Photo attributes" (Code=2511).
type RevisionXAttrCamera struct {
	CaptureTime string `json:",omitempty"` // ISO8601, e.g. "2021-09-16T07:40:54.000Z"
}

type RevisionXAttr struct {
	Common RevisionXAttrCommon
	Camera *RevisionXAttrCamera `json:",omitempty"`
}

func (commitRevisionReq *CommitRevisionReq) SetEncXAttrString(addrKR, nodeKR *crypto.KeyRing, xAttrCommon *RevisionXAttrCommon, camera *RevisionXAttrCamera) error {
	// Source
	// - https://github.com/ProtonMail/WebClients/blob/099a2451b51dea38b5f0e07ec3b8fcce07a88303/packages/shared/lib/interfaces/drive/link.ts#L53
	// - https://github.com/ProtonMail/WebClients/blob/main/applications/drive/src/app/store/_links/extendedAttributes.ts#L139
	// XAttr has following JSON structure encrypted by node key:
	// {
	//    Common: {
	//        ModificationTime: "2021-09-16T07:40:54+0000",
	//        Size: 13283,
	// 		  BlockSizes: [1,2,3],
	//        Digests: "sha1 string"
	//    },
	// }

	jsonByteArr, err := json.Marshal(RevisionXAttr{
		Common: *xAttrCommon,
		Camera: camera,
	})
	if err != nil {
		return err
	}

	encXattr, err := nodeKR.Encrypt(crypto.NewPlainMessage(jsonByteArr), addrKR)
	if err != nil {
		return err
	}

	encXattrString, err := encXattr.GetArmored()
	if err != nil {
		return err
	}

	commitRevisionReq.XAttr = encXattrString
	return nil
}

type BlockToken struct {
	Index int
	Token string
}
