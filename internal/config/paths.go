package config

import (
	"fmt"
	"os"
	"path/filepath"
)

type Paths struct {
	RepoRoot     string
	SubstrateDir string
	ConfigPath   string
	LangMapPath  string
	BaselinePath string
}

func DiscoverFromSubstrateDir(substrateDir string) (Paths, error) {
	abs, err := filepath.Abs(substrateDir)
	if err != nil {
		return Paths{}, fmt.Errorf("config: resolve substrate dir %q: %w", substrateDir, err)
	}
	info, err := os.Stat(abs)
	if err != nil {
		return Paths{}, fmt.Errorf("config: stat substrate dir %q: %w", abs, err)
	}
	if !info.IsDir() {
		return Paths{}, fmt.Errorf("config: substrate dir %q is not a directory", abs)
	}
	repoRoot := filepath.Dir(abs)
	return Paths{
		RepoRoot:     repoRoot,
		SubstrateDir: abs,
		ConfigPath:   filepath.Join(repoRoot, "substrate.json"),
		LangMapPath:  filepath.Join(abs, "langmap.json"),
		BaselinePath: filepath.Join(repoRoot, "substrate-baseline.json"),
	}, nil
}
