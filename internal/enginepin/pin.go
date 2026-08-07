// Package enginepin reads and writes engine.json, the flat two-key
// attestation manifest binding a kit VERSION to the sha256 of the
// substrate-engine binary it was built from (binding B4).
package enginepin

import (
	"fmt"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// Emit hashes the binary at exePath and renders {"version":…,"binary_sha256":…}
// through canonjson in that insertion order, with no trailing newline.
func Emit(exePath, version string) ([]byte, error) {
	sum, err := xshell.SHA256File(exePath)
	if err != nil {
		return nil, fmt.Errorf("enginepin: hash %s: %w", exePath, err)
	}
	doc := canonjson.NewObject().Set("version", version).Set("binary_sha256", sum)
	b, err := canonjson.Marshal(doc)
	if err != nil {
		return nil, fmt.Errorf("enginepin: encode pin: %w", err)
	}
	return b, nil
}
