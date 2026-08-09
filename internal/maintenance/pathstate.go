package maintenance

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func PathState(path string) (string, error) {
	ctx := context.Background()

	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			h := sha256.Sum256([]byte("missing\x00"))
			return fmt.Sprintf("%x", h), nil
		}
		return "", fmt.Errorf("pathstate: stat %s: %w", path, err)
	}

	var records bytes.Buffer

	if info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(path)
		if err != nil {
			return "", fmt.Errorf("pathstate: readlink %s: %w", path, err)
		}
		fmt.Fprintf(&records, "symlink\x00%s\x00", target)
	} else if info.Mode().IsRegular() {
		mode := fmt.Sprintf("%o", info.Mode().Perm())
		result, err := xshell.RunC(ctx, "sha256sum", "--", path)
		if err != nil {
			return "", fmt.Errorf("pathstate: sha256sum %s: %w", path, err)
		}
		hash := strings.Fields(string(result.Stdout))[0]
		fmt.Fprintf(&records, "file\x00%s\x00%s\x00", mode, hash)
	} else if info.IsDir() {
		if err := dirRecords(ctx, &records, path); err != nil {
			return "", err
		}
	} else {
		return "", fmt.Errorf("pathstate: unsupported file type for %s", path)
	}

	h := sha256.Sum256(records.Bytes())
	return fmt.Sprintf("%x", h), nil
}

func dirRecords(ctx context.Context, records *bytes.Buffer, path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("pathstate: stat dir %s: %w", path, err)
	}
	mode := fmt.Sprintf("%o", info.Mode().Perm())
	fmt.Fprintf(records, "dir\x00.\x00%s\x00", mode)

	findResult, err := xshell.RunC(ctx, "find", path, "-mindepth", "1", "-print0")
	if err != nil {
		return fmt.Errorf("pathstate: find %s: %w", path, err)
	}

	sortResult, err := xshell.RunStdinC(ctx, "", findResult.Stdout, "sort", "-z")
	if err != nil {
		return fmt.Errorf("pathstate: sort %s: %w", path, err)
	}

	entries := splitNull(string(sortResult.Stdout))
	for _, node := range entries {
		if node == "" {
			continue
		}
		rel := strings.TrimPrefix(node, path+"/")
		info, err := os.Lstat(node)
		if err != nil {
			return fmt.Errorf("pathstate: stat entry %s: %w", node, err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(node)
			if err != nil {
				return fmt.Errorf("pathstate: readlink entry %s: %w", node, err)
			}
			fmt.Fprintf(records, "symlink\x00%s\x00%s\x00", rel, target)
		} else if info.Mode().IsRegular() {
			mode := fmt.Sprintf("%o", info.Mode().Perm())
			result, err := xshell.RunC(ctx, "sha256sum", "--", node)
			if err != nil {
				return fmt.Errorf("pathstate: sha256sum entry %s: %w", node, err)
			}
			hash := strings.Fields(string(result.Stdout))[0]
			fmt.Fprintf(records, "file\x00%s\x00%s\x00%s\x00", rel, mode, hash)
		} else if info.IsDir() {
			mode := fmt.Sprintf("%o", info.Mode().Perm())
			fmt.Fprintf(records, "dir\x00%s\x00%s\x00", rel, mode)
		} else {
			return fmt.Errorf("pathstate: unsupported file type for entry %s", node)
		}
	}
	return nil
}

func splitNull(s string) []string {
	s = strings.TrimRight(s, "\x00")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\x00")
}


func PreserveModes(candidate string) error {
	ctx := context.Background()
	result, err := xshell.RunC(ctx, "find", candidate, "-mindepth", "1", "-print0")
	if err != nil {
		return fmt.Errorf("preservemodes: find %s: %w", candidate, err)
	}

	entries := splitNull(string(result.Stdout))
	for _, path := range entries {
		if path == "" {
			continue
		}
		rel := strings.TrimPrefix(path, candidate+"/")
		current := "./" + rel

		pathInfo, err := os.Lstat(path)
		if err != nil {
			continue
		}
		currentInfo, err := os.Lstat(current)
		if err != nil {
			continue
		}

		if pathInfo.Mode()&os.ModeSymlink != 0 || currentInfo.Mode()&os.ModeSymlink != 0 {
			continue
		}

		if (pathInfo.Mode().IsRegular() && currentInfo.Mode().IsRegular()) ||
			(pathInfo.IsDir() && currentInfo.IsDir()) {
			if _, err := xshell.Run(ctx, "chmod", "--reference="+current, path); err != nil {
				return fmt.Errorf("preservemodes: chmod %s: %w", path, err)
			}
		}
	}
	return nil
}
