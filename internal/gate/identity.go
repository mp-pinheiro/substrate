package gate

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type vendorIdentity struct {
	KitRevision string `json:"kitRevision"`
	Source      string `json:"source"`
	Version     string `json:"version"`
}

type engineIdentity struct {
	Version      string `json:"version"`
	BinarySHA256 string `json:"binary_sha256"`
}

func verifyEngineIdentity(repoRoot, version, _ string) error {
	vendor, err := readIdentity[vendorIdentity](filepath.Join(repoRoot, ".substrate", "vendor.json"))
	if err != nil {
		return err
	}
	pin, err := readIdentity[engineIdentity](filepath.Join(repoRoot, ".substrate", "engine.json"))
	if err != nil {
		return err
	}
	if vendor.Version == "" || pin.Version == "" {
		return fmt.Errorf("engine provenance incomplete: vendor version %q, pin version %q", vendor.Version, pin.Version)
	}
	if _, err := decodeHex(pin.BinarySHA256, 32); err != nil {
		return fmt.Errorf("engine provenance: invalid binary_sha256: %w", err)
	}

	switch vendor.Source {
	case "worktree":
		if version != vendor.Version {
			return fmt.Errorf("engine provenance mismatch: running %q, worktree requires %q", version, vendor.Version)
		}
		return nil
	case "trunk":
		if _, err := decodeHex(vendor.KitRevision, 20); err != nil {
			return fmt.Errorf("engine provenance: invalid trunk kitRevision: %w", err)
		}
		if version != vendor.Version {
			return fmt.Errorf("engine provenance mismatch: running %q, trunk kit requires %q", version, vendor.Version)
		}
		return nil
	case "release", "nightly", "module":
		release := vendor.Version + "+release"
		nightly := vendor.Version + "+nightly"
		module := vendor.Version + "+module"
		if version != release && version != nightly && version != module {
			return fmt.Errorf("engine provenance mismatch: running %q, published kit requires %q, %q, or %q", version, release, nightly, module)
		}
		return nil
	default:
		return fmt.Errorf("engine provenance: unsupported vendor source %q", vendor.Source)
	}
}

func readIdentity[T any](path string) (T, error) {
	var value T
	data, err := os.ReadFile(path)
	if err != nil {
		return value, fmt.Errorf("engine provenance: read %s: %w", path, err)
	}
	if err := json.Unmarshal(data, &value); err != nil {
		return value, fmt.Errorf("engine provenance: parse %s: %w", path, err)
	}
	return value, nil
}

func decodeHex(value string, bytes int) ([]byte, error) {
	decoded, err := hex.DecodeString(value)
	if err != nil {
		return nil, fmt.Errorf("decode %q: %w", value, err)
	}
	if len(decoded) != bytes {
		return nil, fmt.Errorf("decoded length %d, expected %d", len(decoded), bytes)
	}
	return decoded, nil
}
