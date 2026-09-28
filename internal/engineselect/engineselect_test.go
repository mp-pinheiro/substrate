package engineselect

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func engineScript(version string) []byte {
	return []byte("#!/bin/sh\n[ \"$1\" = version ] && echo " + version + "\n")
}

func consumer(t *testing.T, source, version string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if source != "" {
		if err := os.MkdirAll(filepath.Join(dir, ".substrate"), 0o755); err != nil {
			t.Fatal(err)
		}
		body := fmt.Sprintf(`{"source":%q,"version":%q,"kitRevision":"x"}`, source, version)
		if err := os.WriteFile(filepath.Join(dir, ".substrate", "vendor.json"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	prev, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(prev) })
	t.Setenv("PATH", t.TempDir())
	t.Setenv("SUBSTRATE_ENGINE_CACHE", t.TempDir())
	t.Setenv(GuardEnv, "")
	return dir
}

func pathEngine(t *testing.T, version string) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, engineName)
	if err := os.WriteFile(bin, engineScript(version), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	return bin
}

func release(t *testing.T, version, reported string, corrupt bool) *httptest.Server {
	t.Helper()
	if runtime.GOOS != "linux" {
		t.Skip("published engines exist for linux only")
	}
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	body := engineScript(reported)
	if err := tw.WriteHeader(&tar.Header{Name: "substrate", Mode: 0o755, Size: int64(len(body)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := tw.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := tw.WriteHeader(&tar.Header{Name: "substrate-engine", Linkname: "substrate", Typeflag: tar.TypeSymlink}); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	archive := buf.Bytes()
	asset := fmt.Sprintf("substrate_%s_linux_%s.tar.gz", version, runtime.GOARCH)
	sum := sha256.Sum256(archive)
	digest := hex.EncodeToString(sum[:])
	if corrupt {
		digest = strings.Repeat("0", 64)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v"+version+"/SHA256SUMS", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, "%s  %s\n", digest, asset)
	})
	mux.HandleFunc("/v"+version+"/"+asset, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write(archive)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	t.Setenv("SUBSTRATE_RELEASE_BASE_URL", srv.URL)
	return srv
}

func cachedEngine(t *testing.T, version string) string {
	t.Helper()
	cache, err := CacheDir()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(cache, version, engineName)
}

func TestAcceptsRejectsUnknownSources(t *testing.T) {
	cases := []struct {
		source, running string
		want            bool
	}{
		{"trunk", "1.0.0", true},
		{"trunk", "1.0.0+module", false},
		{"worktree", "1.0.0", true},
		{"release", "1.0.0+release", true},
		{"module", "1.0.0+nightly", true},
		{"release", "1.0.0", false},
		{"local", "1.0.0", false},
		{"", "1.0.0", false},
	}
	for _, c := range cases {
		if got := Accepts(c.source, "1.0.0", c.running); got != c.want {
			t.Errorf("Accepts(%q, 1.0.0, %q) = %v, want %v", c.source, c.running, got, c.want)
		}
	}
}

func TestSelectKeepsMatchingEngine(t *testing.T) {
	consumer(t, "trunk", "1.0.0")
	if bin, _, err := Select("1.0.0"); bin != "" || err != nil {
		t.Fatalf("Select = %q, %v; want the running engine", bin, err)
	}
}

func TestSelectLeavesUnmanagedRepos(t *testing.T) {
	for _, source := range []string{"", "local"} {
		consumer(t, source, "1.0.0")
		if bin, _, err := Select("0.1.0"); bin != "" || err != nil {
			t.Fatalf("source %q: Select = %q, %v; want no selection", source, bin, err)
		}
	}
}

func TestSelectFindsMatchingEngineOnPath(t *testing.T) {
	consumer(t, "trunk", "1.0.0")
	want := pathEngine(t, "1.0.0")
	bin, strict, err := Select("1.0.1")
	if err != nil || bin != want || strict {
		t.Fatalf("Select = %q, %v, %v; want %q, not strict", bin, strict, err, want)
	}
}

func TestSelectTrunkWithoutMatchIsNotStrict(t *testing.T) {
	consumer(t, "trunk", "1.0.0")
	pathEngine(t, "0.9.0")
	bin, strict, err := Select("1.0.1")
	if err == nil || bin != "" || strict {
		t.Fatalf("Select = %q, %v, %v; want a non-strict error", bin, strict, err)
	}
}

func TestSelectInstallsPublishedEngineOnce(t *testing.T) {
	consumer(t, "release", "1.0.0")
	srv := release(t, "1.0.0", "1.0.0+release", false)
	want := cachedEngine(t, "1.0.0")
	bin, strict, err := Select("1.0.0")
	if err != nil || bin != want || !strict {
		t.Fatalf("Select = %q, %v, %v; want %q", bin, strict, err, want)
	}
	if v, err := VersionOf(bin); err != nil || v != "1.0.0+release" {
		t.Fatalf("installed engine reports %q, %v", v, err)
	}
	srv.Close()
	if again, _, err := Select("1.0.0"); err != nil || again != want {
		t.Fatalf("cached Select = %q, %v; want %q without downloading", again, err, want)
	}
}

func TestSelectRefusesUnverifiedDownloads(t *testing.T) {
	cases := map[string]struct {
		reported string
		corrupt  bool
	}{
		"checksum mismatch":      {"1.0.0+release", true},
		"wrong published engine": {"0.9.0+release", false},
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			consumer(t, "release", "1.0.0")
			release(t, "1.0.0", c.reported, c.corrupt)
			bin, strict, err := Select("1.0.0")
			if err == nil || bin != "" || !strict {
				t.Fatalf("Select = %q, %v, %v; want a strict error", bin, strict, err)
			}
			if _, statErr := os.Lstat(filepath.Dir(cachedEngine(t, "1.0.0"))); !os.IsNotExist(statErr) {
				t.Fatalf("an unverified engine was cached: %v", statErr)
			}
		})
	}
}

func TestMaybeFailsClosedForPublishedKits(t *testing.T) {
	consumer(t, "release", "1.0.0")
	srv := release(t, "1.0.0", "1.0.0+release", false)
	srv.Close()
	if code, stop := Maybe([]string{"hook", "protect-paths"}, "1.0.0"); !stop || code != ExitNoEngine {
		t.Fatalf("Maybe offline = %d, %v; want %d and stop", code, stop, ExitNoEngine)
	}
	for _, args := range [][]string{{"maintenance", "update"}, {"version"}} {
		if code, stop := Maybe(args, "1.0.0"); stop || code != 0 {
			t.Fatalf("Maybe %v = %d, %v; the running engine must handle it", args, code, stop)
		}
	}
	t.Setenv(GuardEnv, "1")
	if code, stop := Maybe([]string{"gate"}, "1.0.0"); stop || code != 0 {
		t.Fatalf("Maybe under the guard = %d, %v; a selected engine must not select again", code, stop)
	}
}
