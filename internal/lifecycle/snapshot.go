package lifecycle

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// Snapshot mirrors the bash `snapshot()` output document. Entries is shared
// read-only across Doc() calls; build a fresh Object rather than mutating it in place.
type Snapshot struct {
	Revision    string
	Entries     *canonjson.Object
	Fingerprint string
	Error       string
}

func (s *Snapshot) Doc() *canonjson.Object {
	return canonjson.NewObject().
		Set("revision", s.Revision).
		Set("entries", s.Entries).
		Set("fingerprint", s.Fingerprint).
		Set("error", nullable(s.Error))
}

func (e *Engine) snapshot(ctx context.Context) *Snapshot {
	revision, revisionErr, err := e.repo.Revision(ctx)
	if err != nil {
		revision = ""
		revisionErr = err.Error()
	}

	paths, pathsErr, err := e.repo.ChangedPaths(ctx)
	if err != nil {
		pathsErr = err.Error()
	}

	snapErr := pathsErr
	if revisionErr != "" {
		snapErr = revisionErr
	}

	entries := canonjson.NewObject()
	for _, path := range paths {
		if path == "" {
			continue
		}
		if unsafeChangedPath(path) {
			snapErr = "unsafe changed path: " + path
			break
		}
		entries.Set(path, classifyPath(e.paths.RepoRoot, path))
	}

	fp, ferr := fingerprint(revision, entries)
	if ferr != nil {
		fp = ""
	}

	return &Snapshot{Revision: revision, Entries: entries, Fingerprint: fp, Error: snapErr}
}

func unsafeChangedPath(path string) bool {
	return strings.Contains(path, "\t") ||
		strings.Contains(path, "\n") ||
		strings.HasPrefix(path, "/") ||
		strings.HasPrefix(path, "../") ||
		strings.Contains(path, "/../")
}

func classifyPath(repoRoot, path string) string {
	full := filepath.Join(repoRoot, path)
	info, err := os.Lstat(full)
	if err != nil {
		return "deleted"
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(full)
		if err != nil {
			return "symlink:unreadable"
		}
		return "symlink:" + target
	}
	if info.Mode().IsRegular() {
		sum, err := xshell.SHA256File(full)
		if err != nil {
			sum = ""
		}
		return "file:" + sum
	}
	return "unreadable"
}

func fingerprint(revision string, entries *canonjson.Object) (string, error) {
	doc := canonjson.NewObject().Set("revision", revision).Set("entries", entries)
	b, err := canonjson.MarshalSorted(doc)
	if err != nil {
		return "", fmt.Errorf("lifecycle: marshal fingerprint doc: %w", err)
	}
	b = append(b, '\n')
	return xshell.SHA256Bytes(b), nil
}
