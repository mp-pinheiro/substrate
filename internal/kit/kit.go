package kit

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	substrate "github.com/mp-pinheiro/substrate"
)

const stampName = ".substrate-kit-stamp"

var (
	digestOnce sync.Once
	digestHex  string
	digestErr  error
)

func digest() (string, error) {
	digestOnce.Do(func() {
		sum := sha256.New()
		paths := make([]string, 0, 256)
		err := fs.WalkDir(substrate.Kit, ".", func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				return nil
			}
			paths = append(paths, path)
			return nil
		})
		if err != nil {
			digestErr = fmt.Errorf("walk embedded kit: %w", err)
			return
		}
		sort.Strings(paths)
		for _, p := range paths {
			data, err := substrate.Kit.ReadFile(p)
			if err != nil {
				digestErr = fmt.Errorf("read embedded %s: %w", p, err)
				return
			}
			sum.Write([]byte(p))
			sum.Write([]byte{0})
			sum.Write(data)
		}
		digestHex = hex.EncodeToString(sum.Sum(nil))
	})
	return digestHex, digestErr
}

func Version() string {
	data, err := substrate.Kit.ReadFile("VERSION")
	if err != nil {
		return "0.0.0"
	}
	return strings.TrimSpace(string(data))
}

func cacheBase() (string, error) {
	if base := strings.TrimSpace(os.Getenv("SUBSTRATE_KIT_CACHE")); base != "" {
		return base, nil
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("resolve user cache dir: %w", err)
	}
	return base, nil
}

func mode(path string) os.FileMode {
	if strings.HasPrefix(path, "bin/") || strings.HasSuffix(path, ".sh") {
		return 0o755
	}
	return 0o644
}

func Root() (string, error) {
	if root := strings.TrimSpace(os.Getenv("SUBSTRATE_KIT_ROOT")); root != "" {
		return root, nil
	}
	sum, err := digest()
	if err != nil {
		return "", err
	}
	base, err := cacheBase()
	if err != nil {
		return "", err
	}
	root := filepath.Join(base, "substrate", "kit", Version()+"-"+sum[:12])
	if stamped(root, sum) {
		return root, nil
	}
	if err := materialize(root, sum); err != nil {
		if stamped(root, sum) {
			return root, nil
		}
		return "", err
	}
	return root, nil
}

func stamped(root, sum string) bool {
	data, err := os.ReadFile(filepath.Join(root, stampName))
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(data)) == sum
}

func materialize(root, sum string) error {
	if err := os.MkdirAll(filepath.Dir(root), 0o755); err != nil {
		return fmt.Errorf("create kit cache: %w", err)
	}
	tmp, err := os.MkdirTemp(filepath.Dir(root), filepath.Base(root)+".*.tmp")
	if err != nil {
		return fmt.Errorf("stage kit: %w", err)
	}
	defer func() { _ = os.RemoveAll(tmp) }()

	err = fs.WalkDir(substrate.Kit, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == "." {
			return nil
		}
		target := filepath.Join(tmp, filepath.FromSlash(path))
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := substrate.Kit.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read embedded %s: %w", path, err)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return fmt.Errorf("create %s: %w", filepath.Dir(target), err)
		}
		if err := os.WriteFile(target, data, mode(path)); err != nil {
			return fmt.Errorf("write %s: %w", target, err)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("write kit: %w", err)
	}
	if err := os.WriteFile(filepath.Join(tmp, stampName), []byte(sum+"\n"), 0o644); err != nil {
		return fmt.Errorf("write kit stamp: %w", err)
	}
	if err := os.Rename(tmp, root); err != nil {
		return fmt.Errorf("publish kit at %s: %w", root, err)
	}
	return nil
}

func EngineShim(root string) (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("resolve executable: %w", err)
	}
	exe, err = filepath.Abs(exe)
	if err != nil {
		return "", fmt.Errorf("resolve executable path: %w", err)
	}
	shim := filepath.Join(root, "bin", "substrate-engine")
	body := "#!/usr/bin/env bash\nexec " + shellQuote(exe) + " __engine \"$@\"\n"
	existing, err := os.ReadFile(shim)
	if err == nil && string(existing) == body {
		return shim, nil
	}
	if err := os.MkdirAll(filepath.Dir(shim), 0o755); err != nil {
		return "", fmt.Errorf("create kit bin dir: %w", err)
	}
	if err := os.WriteFile(shim, []byte(body), 0o755); err != nil {
		return "", fmt.Errorf("write engine shim: %w", err)
	}
	return shim, nil
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
