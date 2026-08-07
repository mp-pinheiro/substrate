package receipt

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/mp-pinheiro/substrate/internal/vcs"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

var toolchainCoreSeed = []string{
	"bash", "git", "jq", "yq", "bun", "bunx", "ast-grep", "jscpd", "gitleaks", "actionlint",
}

func computeToolchainHash(ctx context.Context, repo *vcs.Repo, profiles []string) (string, error) {
	seed := append([]string(nil), toolchainCoreSeed...)
	if repo.Kind == vcs.KindJJ {
		seed = append(seed, "jj")
	}
	for _, p := range profiles {
		bins, err := profileToolchainBins(repo.Root, p)
		if err != nil {
			return "", err
		}
		seed = append(seed, bins...)
	}
	bins := dedupeSort(seed)
	return hashItems(bins, toolchainBinRecord)
}

// WHY: an explicit kind field stops two different states hashing alike (H21).
func toolchainBinRecord(bin string) ([]byte, error) {
	path, lookErr := exec.LookPath(bin)
	if lookErr != nil && !errors.Is(lookErr, exec.ErrDot) {
		return joinFields(bin, "absent"), nil
	}
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		real = path
	}
	info, statErr := os.Lstat(real)
	if statErr != nil || !info.Mode().IsRegular() {
		return joinFields(bin, "unresolved", path), nil
	}
	mode := statPermString(info.Mode())
	hash, err := xshell.SHA256File(real)
	if err != nil {
		return nil, fmt.Errorf("receipt: hash %s: %w", real, err)
	}
	pkgHash, err := packageHashForBinary(real)
	if err != nil {
		return nil, err
	}
	return joinFields(bin, "file", mode, hash, pkgHash), nil
}

// WHY: bash walks parents to "/"; the bound excludes a stray
// $HOME/package.json from the digest (H12).
func packageHashForBinary(real string) (string, error) {
	for _, dir := range []string{filepath.Dir(real), filepath.Dir(filepath.Dir(real))} {
		if dir == "" || dir == "." || dir == string(filepath.Separator) {
			continue
		}
		candidate := filepath.Join(dir, "package.json")
		info, err := os.Lstat(candidate)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				continue
			}
			return "", fmt.Errorf("receipt: stat %s: %w", candidate, err)
		}
		if !info.Mode().IsRegular() {
			continue
		}
		hash, hashErr := xshell.SHA256File(candidate)
		if hashErr != nil {
			return "", fmt.Errorf("receipt: hash %s: %w", candidate, hashErr)
		}
		return hash, nil
	}
	return "none", nil
}
