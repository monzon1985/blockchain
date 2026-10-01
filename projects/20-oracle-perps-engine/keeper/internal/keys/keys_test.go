// SPDX-License-Identifier: MIT

package keys

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ethereum/go-ethereum/crypto"
)

func TestWriteLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	key, _ := crypto.GenerateKey()
	path, err := Write(dir, "signer", key, "hunter2", true)
	if err != nil {
		t.Fatal(err)
	}
	pwFile := filepath.Join(dir, "pw")
	if err := os.WriteFile(pwFile, []byte("hunter2\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := Load(path, pwFile)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equal(key) {
		t.Fatal("loaded a different key")
	}

	if err := os.WriteFile(pwFile, []byte("wrong"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path, pwFile); err == nil {
		t.Fatal("wrong password accepted")
	}
	if _, err := Load(filepath.Join(dir, "missing.json"), pwFile); err == nil {
		t.Fatal("missing keystore accepted")
	}
	if _, err := Load(path, filepath.Join(dir, "missing-pw")); err == nil {
		t.Fatal("missing password file accepted")
	}
}
