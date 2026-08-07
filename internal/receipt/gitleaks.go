package receipt

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// GitleaksDeepKey reproduces bash gitleaks_deep_key byte for byte; the digest is a frozen CI cache key (core/gitleaks-lib.sh:57-66, amendment A28).
func GitleaksDeepKey(ctx context.Context, repoRoot string) (string, error) {
	refsHash, err := gitleaksRefsHash(ctx, repoRoot)
	if err != nil {
		return "", err
	}
	version, err := gitleaksVersion(ctx, repoRoot)
	if err != nil {
		return "", err
	}
	configHash, err := gitleaksConfigHash(repoRoot)
	if err != nil {
		return "", err
	}
	preimage := fmt.Sprintf("%s:%s:%s\n", refsHash, version, configHash)
	return xshell.SHA256Bytes([]byte(preimage)), nil
}

// for-each-ref runs in the ambient locale; HEAD's failure is swallowed like bash's `2>/dev/null || true` (core/gitleaks-lib.sh:59-62).
func gitleaksRefsHash(ctx context.Context, repoRoot string) (string, error) {
	refs, err := xshell.RunIn(ctx, repoRoot, "git", "for-each-ref",
		"--format=%(refname) %(objectname)", "refs/heads", "refs/tags", "refs/remotes")
	if err != nil {
		return "", fmt.Errorf("receipt: run git for-each-ref: %w", err)
	}
	head, err := xshell.RunIn(ctx, repoRoot, "git", "rev-parse", "HEAD")
	if err != nil {
		return "", fmt.Errorf("receipt: run git rev-parse HEAD: %w", err)
	}

	var raw bytes.Buffer
	raw.Write(refs.Stdout)
	raw.Write(head.Stdout)

	var stream bytes.Buffer
	for _, line := range sortUniqueLines(raw.String()) {
		stream.WriteString(line)
		stream.WriteByte('\n')
	}
	return xshell.SHA256Bytes(stream.Bytes()), nil
}

// sortUniqueLines reproduces `LC_ALL=C sort -u` on an LF-terminated stream (core/gitleaks-lib.sh:62): Go's string < is already bytewise, so dedup only needs adjacent-pair comparison once sorted.
func sortUniqueLines(s string) []string {
	lines := strings.Split(s, "\n")
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	sort.Strings(lines)

	out := lines[:0]
	for i, line := range lines {
		if i == 0 || line != out[len(out)-1] {
			out = append(out, line)
		}
	}
	return out
}

// tr -d '\r\n' deletes every CR/LF byte rather than trimming, so multi-line gitleaks output concatenates instead of just losing its edges (core/gitleaks-lib.sh:63).
// WHY: bash's outer $(...) around that pipe also silently discards any NUL byte in the captured stream, so stripCRLFAndNUL deletes '\x00' too or the legs' keys diverge (A28).
func gitleaksVersion(ctx context.Context, repoRoot string) (string, error) {
	res, err := xshell.RunIn(ctx, repoRoot, "gitleaks", "version")
	if err != nil {
		return "", fmt.Errorf("receipt: run gitleaks version: %w", err)
	}
	if res.Code != 0 {
		return "", fmt.Errorf("receipt: gitleaks version exited %d", res.Code)
	}
	return stripCRLFAndNUL(string(res.Stdout)), nil
}

func stripCRLFAndNUL(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := range len(s) {
		if c := s[i]; c != '\r' && c != '\n' && c != 0 {
			b.WriteByte(c)
		}
	}
	return b.String()
}

// .gitleaks.toml resolves against repoRoot; any stat failure (missing, non-regular, unreadable) takes bash's `[ -f ]`-false branch, not an error (core/gitleaks-lib.sh:48-55).
func gitleaksConfigHash(repoRoot string) (string, error) {
	configPath := filepath.Join(repoRoot, ".gitleaks.toml")
	info, err := os.Stat(configPath)
	if err != nil || !info.Mode().IsRegular() {
		return "builtin", nil
	}
	sum, err := xshell.SHA256File(configPath)
	if err != nil {
		return "", fmt.Errorf("receipt: hash %s: %w", configPath, err)
	}
	return sum, nil
}
