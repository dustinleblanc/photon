package common

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"

	"github.com/ProtonMail/gopenpgp/v2/crypto"
	"github.com/ProtonMail/go-proton-api"
	"github.com/go-resty/resty/v2"
)

// HVChallenge mirrors what Proton's API returns (Code=9001) in APIError's
// Details field when it wants human verification before allowing a login.
// This fork of go-proton-api doesn't have the official upstream's
// APIHVDetails/GetHVDetails convenience helpers, so we extract it manually
// the same way internal/proton (this project's other login path) does.
type HVChallenge struct {
	Token   string   `json:"HumanVerificationToken"`
	Methods []string `json:"HumanVerificationMethods"`
}

// HVRequiredError signals that a fresh login needs human verification
// before it can proceed. Callers should present Challenge to the user (via
// Proton's hosted verify.proton.me page) and retry Login with
// config.FirstLoginCredential.HVToken/HVMethod set to the solved proof.
type HVRequiredError struct {
	Challenge HVChallenge
}

func (e *HVRequiredError) Error() string {
	return fmt.Sprintf("human verification required (methods: %v)", e.Challenge.Methods)
}

func extractHVChallenge(err error) (*HVChallenge, bool) {
	var apiErr *proton.APIError
	if !errors.As(err, &apiErr) || apiErr.Code != proton.HumanVerificationRequired {
		return nil, false
	}
	data, marshalErr := json.Marshal(apiErr.Details)
	if marshalErr != nil {
		return nil, false
	}
	var challenge HVChallenge
	if err := json.Unmarshal(data, &challenge); err != nil || challenge.Token == "" {
		return nil, false
	}
	return &challenge, true
}

type ProtonDriveCredential struct {
	UID           string
	AccessToken   string
	RefreshToken  string
	SaltedKeyPass string
}

func cacheCredentialToFile(config *Config) error {
	if config.CredentialCacheFile != "" {
		str, err := json.Marshal(config.ReusableCredential)
		if err != nil {
			return err
		}

		file, err := os.Create(config.CredentialCacheFile)
		if err != nil {
			return err
		}
		defer file.Close()
		_, err = file.WriteString(string(str))
		if err != nil {
			return err
		}
	}

	return nil
}

/*
Log in methods
- username and password to log in
- UID and refresh token

Keyring decryption
The password will be salted, and then used to decrypt the keyring. The salted password needs to be and can be cached, so the keyring can be re-decrypted when needed
*/
func Login(ctx context.Context, config *Config, authHandler proton.AuthHandler, deAuthHandler proton.Handler) (*proton.Manager, *proton.Client, *ProtonDriveCredential, *crypto.KeyRing, map[string]*crypto.KeyRing, map[string]proton.Address, error) {
	var c *proton.Client
	var auth proton.Auth
	var userKR *crypto.KeyRing
	var addrKRs map[string]*crypto.KeyRing
	var addrs map[string]proton.Address

	// get manager
	m := getProtonManager(config.AppVersion, config.UserAgent)

	if config.UseReusableLogin {
		c = m.NewClient(config.ReusableCredential.UID, config.ReusableCredential.AccessToken, config.ReusableCredential.RefreshToken)
		c.AddAuthHandler(authHandler)
		c.AddDeauthHandler(deAuthHandler)

		err := cacheCredentialToFile(config)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, err
		}

		SaltedKeyPassByteArr, err := base64.StdEncoding.DecodeString(config.ReusableCredential.SaltedKeyPass)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, err
		}
		userKR, addrKRs, addrs, _, err = getAccountKRs(ctx, c, nil, SaltedKeyPassByteArr)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, err
		}

		return m, c, nil, userKR, addrKRs, addrs, nil
	} else {
		username := config.FirstLoginCredential.Username
		password := config.FirstLoginCredential.Password
		if username == "" || password == "" {
			return nil, nil, nil, nil, nil, nil, ErrUsernameAndPasswordRequired
		}

		// perform login
		var err error
		if config.FirstLoginCredential.HVToken != "" && config.FirstLoginCredential.HVMethod != "" {
			// Matches Proton's own TestApiClient.Router.humanverify header
			// construction (protoncore_ios APIClient/TestAPI.swift) -- these
			// two headers are what the real apps attach to the retried auth
			// request after a human verification challenge is solved.
			hvToken := config.FirstLoginCredential.HVToken
			hvMethod := config.FirstLoginCredential.HVMethod
			m.AddPreRequestHook(func(_ *resty.Client, r *resty.Request) error {
				r.SetHeader("x-pm-human-verification-token-type", hvMethod)
				r.SetHeader("x-pm-human-verification-token", hvToken)
				return nil
			})
		}
		c, auth, err = m.NewClientWithLogin(ctx, username, []byte(password))
		if err != nil {
			if challenge, ok := extractHVChallenge(err); ok {
				return nil, nil, nil, nil, nil, nil, &HVRequiredError{Challenge: *challenge}
			}
			return nil, nil, nil, nil, nil, nil, err
		}
		c.AddAuthHandler(authHandler)
		c.AddDeauthHandler(deAuthHandler)

		if auth.TwoFA.Enabled&proton.HasTOTP != 0 {
			if config.FirstLoginCredential.TwoFA != "" {
				err := c.Auth2FA(ctx, proton.Auth2FAReq{
					TwoFactorCode: config.FirstLoginCredential.TwoFA,
				})
				if err != nil {
					return nil, nil, nil, nil, nil, nil, err
				}
			} else {
				return nil, nil, nil, nil, nil, nil, Err2FACodeRequired
			}
		}

		var keyPass []byte
		if auth.PasswordMode == proton.TwoPasswordMode {
			if config.FirstLoginCredential.MailboxPassword != "" {
				keyPass = []byte(config.FirstLoginCredential.MailboxPassword)
			} else {
				return nil, nil, nil, nil, nil, nil, ErrMailboxPasswordRequired
			}
		} else {
			keyPass = []byte(config.FirstLoginCredential.Password)
		}

		// decrypt keyring
		var saltedKeyPassByteArr []byte
		userKR, addrKRs, addrs, saltedKeyPassByteArr, err = getAccountKRs(ctx, c, keyPass, nil)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, err
		}

		saltedKeyPass := base64.StdEncoding.EncodeToString(saltedKeyPassByteArr)
		config.ReusableCredential.UID = auth.UID
		config.ReusableCredential.AccessToken = auth.AccessToken
		config.ReusableCredential.RefreshToken = auth.RefreshToken
		config.ReusableCredential.SaltedKeyPass = saltedKeyPass

		err = cacheCredentialToFile(config)
		if err != nil {
			return nil, nil, nil, nil, nil, nil, err
		}

		return m, c, &ProtonDriveCredential{
			UID:           auth.UID,
			AccessToken:   auth.AccessToken,
			RefreshToken:  auth.RefreshToken,
			SaltedKeyPass: saltedKeyPass,
		}, userKR, addrKRs, addrs, nil
	}
}

func Logout(ctx context.Context, config *Config, m *proton.Manager, c *proton.Client, userKR *crypto.KeyRing, addrKRs map[string]*crypto.KeyRing) error {
	defer m.Close()
	defer c.Close()

	if config.CredentialCacheFile == "" {
		log.Println("Logging out user")

		// log out
		err := c.AuthDelete(ctx)
		if err != nil {
			return err
		}

		// clear keyrings
		userKR.ClearPrivateParams()

		for i := range addrKRs {
			addrKRs[i].ClearPrivateParams()
		}
	}

	return nil
}
