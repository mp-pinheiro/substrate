package maintenance

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func CollectDirtyPaths(ctx context.Context, vcs string) ([]string, error) {
	var result xshell.Result
	var err error

	if vcs == "jj" {
		result, err = xshell.Run(ctx, "jj", "diff", "--template", `path ++ "\0"`)
	} else {
		var buf bytes.Buffer
		headResult, headErr := xshell.Run(ctx, "git", "rev-parse", "HEAD")
		if headErr == nil && headResult.Code == 0 {
			diffResult, diffErr := xshell.Run(ctx, "git", "diff", "--name-only", "-z", "--no-renames", "HEAD", "--")
			if diffErr != nil {
				return nil, fmt.Errorf("collect dirty paths: git diff: %w", diffErr)
			}
			buf.Write(diffResult.Stdout)
		} else {
			cachedResult, cachedErr := xshell.Run(ctx, "git", "ls-files", "-z", "--cached")
			if cachedErr != nil {
				return nil, fmt.Errorf("collect dirty paths: git ls-files cached: %w", cachedErr)
			}
			buf.Write(cachedResult.Stdout)
		}
		otherResult, otherErr := xshell.Run(ctx, "git", "ls-files", "-z", "--others", "--exclude-standard")
		if otherErr != nil {
			return nil, fmt.Errorf("collect dirty paths: git ls-files others: %w", otherErr)
		}
		buf.Write(otherResult.Stdout)
		result = xshell.Result{Stdout: buf.Bytes()}
	}

	if err != nil {
		return nil, fmt.Errorf("collect dirty paths: %w", err)
	}

	parts := bytes.Split(bytes.TrimRight(result.Stdout, "\x00"), []byte("\x00"))
	paths := make([]string, 0, len(parts))
	for _, p := range parts {
		if len(p) == 0 {
			continue
		}
		paths = append(paths, string(p))
	}

	sort.Strings(paths)
	unique := paths[:0]
	for i, p := range paths {
		if i == 0 || p != paths[i-1] {
			unique = append(unique, p)
		}
	}
	return unique, nil
}

func EntryState(path string) (string, error) {
	fi, err := os.Lstat(path)
	if err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("entry state: lstat %s: %w", path, err)
	}

	if fi != nil && fi.IsDir() && fi.Mode()&os.ModeSymlink == 0 {
		ctx := context.Background()
		revResult, revErr := xshell.RunIn(ctx, path, "git", "rev-parse", "HEAD")
		if revErr == nil && revResult.Code == 0 {
			statusResult, statusErr := xshell.RunIn(ctx, path, "git", "status", "--porcelain=v1", "--untracked-files=all")
			if statusErr != nil {
				return "", fmt.Errorf("entry state: git status %s: %w", path, statusErr)
			}
			head := strings.TrimSpace(string(revResult.Stdout))
			statusSum := sha256.Sum256(statusResult.Stdout)
			return fmt.Sprintf("submodule:%s:%s", head, hex.EncodeToString(statusSum[:])), nil
		}
	}

	return PathState(path)
}


func EntriesJSON(ctx context.Context, paths []string, manifest []string, selection string) (map[string]string, error) {
	entries := make(map[string]string)
	for _, p := range paths {
		if err := validatePath(p); err != nil {
			return nil, err
		}
		inManifest := PathInManifest(p, manifest)
		if selection == "inside" && !inManifest {
			continue
		}
		if selection == "outside" && inManifest {
			continue
		}
		state, err := EntryState(p)
		if err != nil {
			return nil, fmt.Errorf("entries json: %s: %w", p, err)
		}
		entries[p] = state
	}
	return entries, nil
}

func JSONFingerprint(data string) (string, error) {
	v, err := canonjson.Unmarshal([]byte(data))
	if err != nil {
		return "", fmt.Errorf("json fingerprint: parse: %w", err)
	}
	normalized, err := canonjson.MarshalSorted(v)
	if err != nil {
		return "", fmt.Errorf("json fingerprint: normalize: %w", err)
	}
	sum := sha256.Sum256(normalized)
	return hex.EncodeToString(sum[:]), nil
}

func validatePath(p string) error {
	if p == "" || filepath.IsAbs(p) {
		return fmt.Errorf("validate path: invalid path: %s", p)
	}
	if strings.Contains(p, "..") {
		return fmt.Errorf("validate path: path contains ..: %s", p)
	}
	if strings.Contains(p, "\t") || strings.Contains(p, "\n") {
		return fmt.Errorf("validate path: path contains control characters: %s", p)
	}
	return nil
}
