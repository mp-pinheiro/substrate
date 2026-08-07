package receipt

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

type profileToolchainEntry struct {
	Bin string `json:"bin"`
}

type profileTemplateEntry struct {
	Dest string `json:"dest"`
}

type profileManifest struct {
	Toolchain []profileToolchainEntry `json:"toolchain"`
	Templates []profileTemplateEntry  `json:"templates"`
}

func loadProfileManifest(repoRoot, profile string) (*profileManifest, error) {
	path := filepath.Join(repoRoot, ".substrate", "profiles", profile, "profile.json")
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("receipt: read %s: %w", path, err)
	}
	var manifest profileManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, fmt.Errorf("receipt: parse %s: %w", path, err)
	}
	return &manifest, nil
}

// profileField loads the manifest, then extracts and filters one field —
// the load+nil-check shape profileToolchainBins and profileTemplateDests share.
func profileField[T any](repoRoot, profile string, field func(*profileManifest) []T, get func(T) string) ([]string, error) {
	manifest, err := loadProfileManifest(repoRoot, profile)
	if err != nil || manifest == nil {
		return nil, err
	}
	return nonEmptyStrings(field(manifest), get), nil
}

func profileToolchainBins(repoRoot, profile string) ([]string, error) {
	return profileField(repoRoot, profile,
		func(m *profileManifest) []profileToolchainEntry { return m.Toolchain },
		func(e profileToolchainEntry) string { return e.Bin })
}

func profileTemplateDests(repoRoot, profile string) ([]string, error) {
	return profileField(repoRoot, profile,
		func(m *profileManifest) []profileTemplateEntry { return m.Templates },
		func(e profileTemplateEntry) string { return e.Dest })
}

// nonEmptyStrings extracts get(item) from each item, dropping empty results
// — the filter shape profileToolchainBins and profileTemplateDests share.
func nonEmptyStrings[T any](items []T, get func(T) string) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		if v := get(item); v != "" {
			out = append(out, v)
		}
	}
	return out
}
