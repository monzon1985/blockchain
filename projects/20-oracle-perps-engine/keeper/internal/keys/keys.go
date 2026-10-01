// SPDX-License-Identifier: MIT

// Package keys loads and writes Web3 Secret Storage (geth keystore) files. Services only ever read keys from
// encrypted keystores; raw private keys are never accepted on the command line or in environment variables.
package keys

import (
	"crypto/ecdsa"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/keystore"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/google/uuid"
)

// Load decrypts keystoreFile with the password stored in passwordFile (trailing newlines are ignored).
func Load(keystoreFile, passwordFile string) (*ecdsa.PrivateKey, error) {
	blob, err := os.ReadFile(keystoreFile)
	if err != nil {
		return nil, fmt.Errorf("read keystore: %w", err)
	}
	pw, err := os.ReadFile(passwordFile)
	if err != nil {
		return nil, fmt.Errorf("read password file: %w", err)
	}
	key, err := keystore.DecryptKey(blob, strings.TrimRight(string(pw), "\r\n"))
	if err != nil {
		return nil, fmt.Errorf("decrypt keystore %s: %w", keystoreFile, err)
	}
	return key.PrivateKey, nil
}

// Write encrypts key into dir/<name>.json. light selects cheap scrypt parameters (tests and local demos only).
func Write(dir, name string, key *ecdsa.PrivateKey, password string, light bool) (string, error) {
	id, err := uuid.NewRandom()
	if err != nil {
		return "", err
	}
	n, p := keystore.StandardScryptN, keystore.StandardScryptP
	if light {
		n, p = keystore.LightScryptN, keystore.LightScryptP
	}
	blob, err := keystore.EncryptKey(&keystore.Key{
		Id: id, Address: crypto.PubkeyToAddress(key.PublicKey), PrivateKey: key,
	}, password, n, p)
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, name+".json")
	return path, os.WriteFile(path, blob, 0o600)
}
