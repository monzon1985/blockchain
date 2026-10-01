// SPDX-License-Identifier: MIT

// Package signer holds the hot-wallet key behind a narrow interface and a signing firewall
// that re-validates every transaction immediately before it is signed.
//
// Signer is the extension point for other key backends: a cloud KMS (secp256k1 keys in AWS KMS
// or GCP KMS), an HSM, or an MPC cluster only need Address and SignTx. The firewall sits in front
// of whatever backend is configured, so policy does not depend on the backend being careful.
package signer

import (
	"context"
	"crypto/ecdsa"
	"errors"
	"fmt"
	"math/big"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/keystore"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/google/uuid"
)

// Signer signs transactions for one address.
type Signer interface {
	// Address is the account the signer controls.
	Address() common.Address
	// SignTx signs tx for chainID.
	SignTx(ctx context.Context, tx *types.Transaction, chainID *big.Int) (*types.Transaction, error)
}

// LocalKeystoreSigner keeps a secp256k1 key in process memory. It is the only backend shipped here;
// see the package documentation for the others the interface is designed for.
type LocalKeystoreSigner struct {
	key  *ecdsa.PrivateKey
	addr common.Address
}

// NewLocalKeystoreSigner wraps an in-memory key (tests and the simulator).
func NewLocalKeystoreSigner(key *ecdsa.PrivateKey) *LocalKeystoreSigner {
	return &LocalKeystoreSigner{key: key, addr: crypto.PubkeyToAddress(key.PublicKey)}
}

// LoadKeystore decrypts a Web3 Secret Storage (keystore v3) file with the password stored in
// passwordFile. Trailing newlines in the password file are ignored.
func LoadKeystore(keystoreFile, passwordFile string) (*LocalKeystoreSigner, error) {
	blob, err := os.ReadFile(keystoreFile)
	if err != nil {
		return nil, fmt.Errorf("signer: read keystore: %w", err)
	}
	pass, err := os.ReadFile(passwordFile)
	if err != nil {
		return nil, fmt.Errorf("signer: read password file: %w", err)
	}
	key, err := keystore.DecryptKey(blob, strings.TrimRight(string(pass), "\r\n"))
	if err != nil {
		return nil, fmt.Errorf("signer: decrypt keystore: %w", err)
	}
	return NewLocalKeystoreSigner(key.PrivateKey), nil
}

// EncryptKeystore returns the keystore v3 JSON of key under password. light selects the cheap
// scrypt parameters (tests only).
func EncryptKeystore(key *ecdsa.PrivateKey, password string, light bool) ([]byte, error) {
	n, p := keystore.StandardScryptN, keystore.StandardScryptP
	if light {
		n, p = keystore.LightScryptN, keystore.LightScryptP
	}
	id, err := uuid.NewRandom()
	if err != nil {
		return nil, err
	}
	k := &keystore.Key{Id: id, Address: crypto.PubkeyToAddress(key.PublicKey), PrivateKey: key}
	return keystore.EncryptKey(k, password, n, p)
}

// Address implements Signer.
func (s *LocalKeystoreSigner) Address() common.Address { return s.addr }

// SignTx implements Signer.
func (s *LocalKeystoreSigner) SignTx(_ context.Context, tx *types.Transaction, chainID *big.Int) (*types.Transaction, error) {
	if chainID == nil || chainID.Sign() <= 0 {
		return nil, errors.New("signer: chain id required")
	}
	return types.SignTx(tx, types.LatestSignerForChainID(chainID), s.key)
}
