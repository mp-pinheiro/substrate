package receipt

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// computeEngineHash rejects an unwalkable .substrate root: bash's find|sort pipeline
// digests an empty record set into a normal-looking hash when the root is gone (H6/A31).
func computeEngineHash(repoRoot string) (string, error) {
	root := filepath.Join(repoRoot, ".substrate")
	info, err := os.Lstat(root)
	if err != nil {
		return "", fmt.Errorf("receipt: engine root %s: %w", root, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("receipt: engine root %s is not a directory", root)
	}

	var records [][]byte
	walkErr := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("receipt: walk %s: %w", path, err)
		}
		if d.IsDir() {
			return nil
		}
		rel, relErr := relSlash(repoRoot, path)
		if relErr != nil {
			return relErr
		}

		if d.Type()&fs.ModeSymlink != 0 {
			target, readErr := os.Readlink(path)
			if readErr != nil {
				return fmt.Errorf("receipt: readlink %s: %w", path, readErr)
			}
			records = append(records, joinFields(rel, "symlink", target))
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		lst, statErr := os.Lstat(path)
		if statErr != nil {
			return fmt.Errorf("receipt: stat %s: %w", path, statErr)
		}
		hash, hashErr := xshell.SHA256File(path)
		if hashErr != nil {
			return fmt.Errorf("receipt: hash %s: %w", path, hashErr)
		}
		mode := statPermString(lst.Mode())
		records = append(records, joinFields(rel, "file", mode, hash))
		return nil
	})
	if walkErr != nil {
		return "", fmt.Errorf("receipt: walk %s: %w", root, walkErr)
	}
	if len(records) == 0 {
		return "", fmt.Errorf("receipt: engine root %s has no records", root)
	}
	return hashRecords(records)
}
