package receipt

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
)

func splitRecordFields(t *testing.T, record []byte) []string {
	t.Helper()
	var fields []string
	for i := 0; i < len(record); {
		j := i
		for j < len(record) && record[j] != lenDelim {
			j++
		}
		if j >= len(record) {
			t.Fatalf("malformed record %q: no length delimiter", record)
		}
		n, err := strconv.Atoi(string(record[i:j]))
		if err != nil {
			t.Fatalf("malformed record %q: bad field length: %v", record, err)
		}
		start, end := j+1, j+1+n
		if n < 0 || end > len(record) {
			t.Fatalf("malformed record %q: field length %d out of range", record, n)
		}
		fields = append(fields, string(record[start:end]))
		i = end
	}
	return fields
}

// H21: absent/unresolved/file must never collapse into look-alike records —
// each kind carries its own tag and field count.
func TestToolchainRecordKindsDistinguishable(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir)

	absent, err := toolchainBinRecord("definitely-absent-bin-xyz")
	if err != nil {
		t.Fatalf("toolchainBinRecord(absent): %v", err)
	}
	absentFields := splitRecordFields(t, absent)
	if len(absentFields) != 2 || absentFields[1] != "absent" {
		t.Fatalf("absent record = %q, want 2 fields tagged absent", absent)
	}

	fifoPath := filepath.Join(dir, "pipetool")
	if err := syscall.Mkfifo(fifoPath, 0o755); err != nil {
		t.Fatalf("mkfifo: %v", err)
	}
	unresolved, err := toolchainBinRecord("pipetool")
	if err != nil {
		t.Fatalf("toolchainBinRecord(unresolved): %v", err)
	}
	unresolvedFields := splitRecordFields(t, unresolved)
	if len(unresolvedFields) != 3 || unresolvedFields[1] != "unresolved" {
		t.Fatalf("unresolved record = %q, want 3 fields tagged unresolved", unresolved)
	}

	content := []byte("footool body\n")
	toolPath := filepath.Join(dir, "footool")
	if err := os.WriteFile(toolPath, content, 0o755); err != nil {
		t.Fatalf("write footool: %v", err)
	}
	if err := os.Chmod(toolPath, 0o755); err != nil {
		t.Fatalf("chmod footool: %v", err)
	}
	fileRecord, err := toolchainBinRecord("footool")
	if err != nil {
		t.Fatalf("toolchainBinRecord(file): %v", err)
	}
	fileFields := splitRecordFields(t, fileRecord)
	if len(fileFields) != 5 || fileFields[1] != "file" {
		t.Fatalf("file record = %q, want 5 fields tagged file", fileRecord)
	}
	if fileFields[2] != "755" {
		t.Errorf("file record mode = %q, want 755", fileFields[2])
	}
	sum := sha256.Sum256(content)
	if want := hex.EncodeToString(sum[:]); fileFields[3] != want {
		t.Errorf("file record hash = %q, want %q", fileFields[3], want)
	}
	if fileFields[4] != "none" {
		t.Errorf("file record package hash = %q, want none (no package.json in tree)", fileFields[4])
	}

	if string(absent) == string(unresolved) || string(unresolved) == string(fileRecord) || string(absent) == string(fileRecord) {
		t.Fatalf("record kinds are not pairwise distinct: absent=%q unresolved=%q file=%q", absent, unresolved, fileRecord)
	}
}

// R4: Go 1.19+ pairs exec.ErrDot with a still-valid path for a relative PATH
// hit; discarding the whole result on any error recorded a real tool absent.
func TestToolchainBinRecordResolvesRelativePATHHit(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "relbin"), 0o755); err != nil {
		t.Fatal(err)
	}
	content := []byte("#!/bin/sh\necho hi\n")
	toolPath := filepath.Join(dir, "relbin", "mytool")
	if err := os.WriteFile(toolPath, content, 0o755); err != nil {
		t.Fatal(err)
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", "relbin")

	record, err := toolchainBinRecord("mytool")
	if err != nil {
		t.Fatalf("toolchainBinRecord: %v", err)
	}
	fields := splitRecordFields(t, record)
	if fields[1] != "file" {
		t.Fatalf("record = %q, want kind=file for a resolvable relative-PATH hit", record)
	}
	sum := sha256.Sum256(content)
	if want := hex.EncodeToString(sum[:]); fields[3] != want {
		t.Errorf("record hash = %q, want %q", fields[3], want)
	}
}
