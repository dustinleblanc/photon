package proton

import "encoding/base64"

// VerificationCodeFromContentKeyPacket derives the verification code for a
// newly-created ("small") file: the last 32 bytes of the (non-base64) raw
// content key packet. Confirmed from Proton's own official Drive SDK
// (SmallFileBlockVerifier.getVerificationCode, client/js/src/internal/
// upload/blockVerifier.ts): `contentKeyPacket.subarray(-32)`.
func VerificationCodeFromContentKeyPacket(rawContentKeyPacket []byte) []byte {
	if len(rawContentKeyPacket) < 32 {
		return rawContentKeyPacket
	}
	return rawContentKeyPacket[len(rawContentKeyPacket)-32:]
}

// BuildVerificationToken computes the per-block verifier the current
// /drive/blocks endpoint requires. Confirmed from Proton's own official
// Drive SDK (cryptoService.ts verifyBlock): each byte of the verification
// code is XORed with the corresponding byte of the encrypted block data
// (missing bytes treated as 0), then base64-encoded.
func BuildVerificationToken(verificationCode []byte, encryptedBlock []byte) string {
	token := make([]byte, len(verificationCode))
	for i, v := range verificationCode {
		var b byte
		if i < len(encryptedBlock) {
			b = encryptedBlock[i]
		}
		token[i] = v ^ b
	}
	return base64.StdEncoding.EncodeToString(token)
}
