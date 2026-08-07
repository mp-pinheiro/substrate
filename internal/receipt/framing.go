package receipt

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// v2 hashers length-prefix each field (decimal count, ':', raw bytes); 0x1F/0x1E are legal
// path bytes and unescaped separators let one record's bytes alias two records' (B5/H1/H14).
const lenDelim = ':'

func joinFields(fields ...string) []byte {
	var buf bytes.Buffer
	for _, f := range fields {
		buf.WriteString(strconv.Itoa(len(f)))
		buf.WriteByte(lenDelim)
		buf.WriteString(f)
	}
	return buf.Bytes()
}

// hashRecords sorts (H3/H8-H9) then length-prefixes each record so no
// record's bytes can alias a different split of the sorted stream.
func hashRecords(records [][]byte) (string, error) {
	sort.Slice(records, func(i, j int) bool { return bytes.Compare(records[i], records[j]) < 0 })
	h := sha256.New()
	for _, r := range records {
		if _, err := fmt.Fprintf(h, "%d%c", len(r), lenDelim); err != nil {
			return "", fmt.Errorf("receipt: hash record header: %w", err)
		}
		if _, err := h.Write(r); err != nil {
			return "", fmt.Errorf("receipt: hash record: %w", err)
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// hashItems is the enumerate → per-item record → digest shape every v2
// hasher shares: build one record per item, then hashRecords sorts and digests them.
func hashItems[T any](items []T, build func(T) ([]byte, error)) (string, error) {
	var records [][]byte
	for _, item := range items {
		record, err := build(item)
		if err != nil {
			return "", err
		}
		records = append(records, record)
	}
	return hashRecords(records)
}

// fileState mirrors bash's hash_file_state (receipt-lib.sh:47-56), except bash's
// "unreadable" readlink sentinel becomes a hard error: v2 hashers fail closed.
func fileState(path string) (kind, mode, value string, err error) {
	info, statErr := os.Lstat(path)
	if statErr != nil {
		if errors.Is(statErr, fs.ErrNotExist) {
			return "missing", "", "", nil
		}
		return "", "", "", fmt.Errorf("receipt: stat %s: %w", path, statErr)
	}
	if info.Mode()&fs.ModeSymlink != 0 {
		target, readErr := os.Readlink(path)
		if readErr != nil {
			return "", "", "", fmt.Errorf("receipt: readlink %s: %w", path, readErr)
		}
		return "symlink", "", target, nil
	}
	if !info.Mode().IsRegular() {
		return "missing", "", "", nil
	}
	hash, hashErr := xshell.SHA256File(path)
	if hashErr != nil {
		return "", "", "", fmt.Errorf("receipt: hash %s: %w", path, hashErr)
	}
	return "file", statPermString(info.Mode()), hash, nil
}

// statPermString reproduces GNU `stat -c '%a'`: Perm() alone masks off
// setuid/setgid/sticky, so chmod 4755/2755/1755 would digest like 0755.
func statPermString(mode fs.FileMode) string {
	perm := uint32(mode.Perm())
	if mode&fs.ModeSetuid != 0 {
		perm |= 0o4000
	}
	if mode&fs.ModeSetgid != 0 {
		perm |= 0o2000
	}
	if mode&fs.ModeSticky != 0 {
		perm |= 0o1000
	}
	return fmt.Sprintf("%o", perm)
}

// fileStateRecord is the per-tracked-path record shape repository and
// configuration hashing share.
func fileStateRecord(root, rel string) ([]byte, error) {
	kind, mode, value, err := fileState(filepath.Join(root, rel))
	if err != nil {
		return nil, err
	}
	switch kind {
	case "symlink":
		return joinFields(rel, "symlink", value), nil
	case "file":
		return joinFields(rel, "file", mode, value), nil
	default:
		return joinFields(rel, "missing"), nil
	}
}

// relSlash converts path to a POSIX-style path relative to root, matching
// bash's forward-slash-only convention regardless of OS.
func relSlash(root, path string) (string, error) {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return "", fmt.Errorf("receipt: relativize %s: %w", path, err)
	}
	return filepath.ToSlash(rel), nil
}

// dedupeSort sorts by raw byte order (Go's string < is byte compare) and
// drops consecutive duplicates.
func dedupeSort(xs []string) []string {
	if len(xs) == 0 {
		return nil
	}
	out := append([]string(nil), xs...)
	sort.Strings(out)
	j := 0
	for i := 1; i < len(out); i++ {
		if out[i] != out[j] {
			j++
			out[j] = out[i]
		}
	}
	return out[:j+1]
}
