package engineselect

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

const (
	GuardEnv       = "SUBSTRATE_ENGINE_SELECTED"
	ExitNoEngine   = 12
	defaultBaseURL = "https://github.com/mp-pinheiro/substrate/releases/download"
	engineName     = "substrate-engine"
)

type vendorIdentity struct {
	Source  string `json:"source"`
	Version string `json:"version"`
}

func Published(source string) bool {
	return source == "release" || source == "nightly" || source == "module"
}

func known(source string) bool {
	return Published(source) || source == "trunk" || source == "worktree"
}

func Accepts(source, required, running string) bool {
	if Published(source) {
		return running == required+"+release" || running == required+"+nightly" || running == required+"+module"
	}
	return known(source) && running == required
}

func Maybe(args []string, running string) (int, bool) {
	if len(args) == 0 || os.Getenv(GuardEnv) != "" {
		return 0, false
	}
	switch args[0] {
	case "version", "pin", "capabilities", "maintenance":
		return 0, false
	}
	bin, strict, err := Select(running)
	if err == nil && bin != "" {
		err = syscall.Exec(bin, append([]string{bin}, args...), append(os.Environ(), GuardEnv+"=1"))
		err = fmt.Errorf("exec %s: %w", bin, err)
	}
	if err == nil {
		return 0, false
	}
	if strict {
		fmt.Fprintf(os.Stderr, "substrate-engine: %v\n", err)
		return ExitNoEngine, true
	}
	fmt.Fprintf(os.Stderr, "substrate-engine: %v; continuing with engine %s\n", err, running)
	return 0, false
}

func Select(running string) (string, bool, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", false, nil
	}
	root, vendor, ok := findVendor(cwd)
	if !ok || vendor.Version == "" || !known(vendor.Source) || Accepts(vendor.Source, vendor.Version, running) {
		return "", false, nil
	}
	strict := Published(vendor.Source)
	if bin := searchPath(vendor); bin != "" {
		return bin, strict, nil
	}
	if !strict {
		return "", false, fmt.Errorf("%s vendors %s kit %s and no %s on PATH reports that version", root, vendor.Source, vendor.Version, engineName)
	}
	bin, err := install(vendor)
	if err != nil {
		return "", true, fmt.Errorf("%s vendors published kit %s and its engine is unavailable: %w; connect once to download it, or run go install github.com/mp-pinheiro/substrate/cmd/substrate@v%s and put it on PATH as %s", root, vendor.Version, err, vendor.Version, engineName)
	}
	return bin, true, nil
}

func findVendor(dir string) (string, vendorIdentity, bool) {
	for {
		data, err := os.ReadFile(filepath.Join(dir, ".substrate", "vendor.json"))
		if err == nil {
			var v vendorIdentity
			if json.Unmarshal(data, &v) != nil {
				return "", v, false
			}
			return dir, v, true
		}
		if exists(filepath.Join(dir, ".git")) || exists(filepath.Join(dir, ".jj")) {
			return "", vendorIdentity{}, false
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", vendorIdentity{}, false
		}
		dir = parent
	}
}

func searchPath(vendor vendorIdentity) string {
	self := resolved(executable())
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if dir == "" {
			continue
		}
		candidate := filepath.Join(dir, engineName)
		if !isExecutable(candidate) || resolved(candidate) == self {
			continue
		}
		if version, err := VersionOf(candidate); err == nil && Accepts(vendor.Source, vendor.Version, version) {
			return candidate
		}
	}
	return ""
}

func VersionOf(bin string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "version")
	cmd.Env = append(os.Environ(), GuardEnv+"=1")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("%s version: %w", bin, err)
	}
	return strings.TrimSpace(string(out)), nil
}

func CacheDir() (string, error) {
	if dir := strings.TrimSpace(os.Getenv("SUBSTRATE_ENGINE_CACHE")); dir != "" {
		return dir, nil
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("resolve user cache dir: %w", err)
	}
	return filepath.Join(base, "substrate", "engines"), nil
}

func install(vendor vendorIdentity) (string, error) {
	cache, err := CacheDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(cache, vendor.Version)
	link := filepath.Join(dir, engineName)
	if isExecutable(link) {
		version, err := VersionOf(link)
		if err == nil && Accepts(vendor.Source, vendor.Version, version) {
			return link, nil
		}
		return "", fmt.Errorf("cached engine %s reports %q, not published %s; delete %s to reinstall", link, version, vendor.Version, dir)
	}
	if runtime.GOOS != "linux" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		return "", fmt.Errorf("no published engine for %s/%s; run go install github.com/mp-pinheiro/substrate/cmd/substrate@v%s and put it on PATH as %s", runtime.GOOS, runtime.GOARCH, vendor.Version, engineName)
	}
	base := strings.TrimRight(os.Getenv("SUBSTRATE_RELEASE_BASE_URL"), "/")
	if base == "" {
		base = defaultBaseURL
	}
	asset := fmt.Sprintf("substrate_%s_linux_%s.tar.gz", vendor.Version, runtime.GOARCH)
	release := base + "/v" + vendor.Version
	fmt.Fprintf(os.Stderr, "substrate-engine: installing published engine %s into %s\n", vendor.Version, dir)

	sums, err := fetch(release + "/SHA256SUMS")
	if err != nil {
		return "", err
	}
	want, err := checksumFor(sums, asset)
	if err != nil {
		return "", err
	}
	archive, err := fetch(release + "/" + asset)
	if err != nil {
		return "", err
	}
	got := sha256.Sum256(archive)
	if hex.EncodeToString(got[:]) != want {
		return "", fmt.Errorf("%s: sha256 %s does not match SHA256SUMS %s", asset, hex.EncodeToString(got[:]), want)
	}

	if err := stage(cache, vendor, archive, asset); err != nil {
		return "", err
	}
	return link, nil
}

func stage(cache string, vendor vendorIdentity, archive []byte, asset string) (err error) {
	dir := filepath.Join(cache, vendor.Version)
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return fmt.Errorf("create engine cache: %w", err)
	}
	staging, err := os.MkdirTemp(cache, ".install-"+vendor.Version+"-")
	if err != nil {
		return fmt.Errorf("create engine staging dir: %w", err)
	}
	defer func() {
		if cleanupErr := os.RemoveAll(staging); cleanupErr != nil && err == nil {
			err = fmt.Errorf("remove engine staging dir: %w", cleanupErr)
		}
	}()
	if err := extractBinary(archive, filepath.Join(staging, "substrate")); err != nil {
		return fmt.Errorf("%s: %w", asset, err)
	}
	if err := os.Symlink("substrate", filepath.Join(staging, engineName)); err != nil {
		return fmt.Errorf("link staged engine: %w", err)
	}
	version, err := VersionOf(filepath.Join(staging, engineName))
	if err != nil {
		return fmt.Errorf("%s: engine does not run: %w", asset, err)
	}
	if !Accepts(vendor.Source, vendor.Version, version) {
		return fmt.Errorf("%s: engine reports %q, not published %s", asset, version, vendor.Version)
	}
	if err := os.Rename(staging, dir); err != nil && !isExecutable(filepath.Join(dir, engineName)) {
		return fmt.Errorf("install engine into %s: %w", dir, err)
	}
	return nil
}

func fetch(url string) (body []byte, err error) {
	client := &http.Client{Timeout: 2 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("download %s: %w", url, err)
	}
	defer func() {
		if closeErr := resp.Body.Close(); closeErr != nil && err == nil {
			err = fmt.Errorf("download %s: %w", url, closeErr)
		}
	}()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("download %s: HTTP %d", url, resp.StatusCode)
	}
	body, err = io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("download %s: %w", url, err)
	}
	return body, nil
}

func checksumFor(sums []byte, asset string) (string, error) {
	scanner := bufio.NewScanner(bytes.NewReader(sums))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == asset {
			return strings.ToLower(fields[0]), nil
		}
	}
	return "", fmt.Errorf("SHA256SUMS has no entry for %s", asset)
}

func extractBinary(archive []byte, dest string) error {
	gz, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return fmt.Errorf("open archive: %w", err)
	}
	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return errors.New("archive has no substrate binary")
		}
		if err != nil {
			return fmt.Errorf("read archive: %w", err)
		}
		if hdr.Typeflag != tar.TypeReg || filepath.Clean(hdr.Name) != "substrate" {
			continue
		}
		return writeBinary(dest, tr)
	}
}

func writeBinary(dest string, src io.Reader) (err error) {
	out, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return fmt.Errorf("create %s: %w", dest, err)
	}
	defer func() {
		if closeErr := out.Close(); closeErr != nil && err == nil {
			err = fmt.Errorf("write %s: %w", dest, closeErr)
		}
	}()
	if _, err := io.Copy(out, src); err != nil {
		return fmt.Errorf("write %s: %w", dest, err)
	}
	return nil
}

func executable() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return exe
}

func resolved(path string) string {
	if path == "" {
		return ""
	}
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return path
	}
	return real
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && info.Mode()&0o111 != 0
}
