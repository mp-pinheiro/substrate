package maintenance

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func BaseMarkerOwned(ctx context.Context, base, marker string) bool {
	if base == "" {
		return false
	}
	result, err := xshell.Run(ctx, "git", "show", base+":"+marker)
	if err != nil || result.Code != 0 {
		return false
	}
	var m struct {
		ManagedBy string `json:"managed_by"`
	}
	if err := json.Unmarshal(result.Stdout, &m); err != nil {
		return false
	}
	return m.ManagedBy == "substrate"
}

func DirtyPathRepairable(ctx context.Context, base, path string) bool {
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode()&os.ModeSymlink != 0 || !fi.Mode().IsRegular() {
			return false
		}
	}

	switch {
	case strings.HasPrefix(path, ".substrate/"):
		_, err := xshell.Run(ctx, "git", "cat-file", "-e", base+":.substrate/VERSION")
		return err == nil

	case path == ".omp/extensions/substrate-quality.ts":
		left, err := xshell.Run(ctx, "git", "show", base+":"+path)
		if err != nil || left.Code != 0 {
			return false
		}
		right, err := xshell.Run(ctx, "git", "show", base+":core/omp/substrate-quality.ts")
		if err != nil || right.Code != 0 {
			return false
		}
		return bytes.Equal(left.Stdout, right.Stdout)

	case strings.HasPrefix(path, ".github/workflows/"):
		result, err := xshell.Run(ctx, "git", "show", base+":"+path)
		if err != nil || result.Code != 0 {
			return false
		}
		first, _, _ := strings.Cut(string(result.Stdout), "\n")
		return first == "# substrate-managed"

	case strings.HasSuffix(path, ".substrate-managed.json"):
		return BaseMarkerOwned(ctx, base, path)
	}

	marker := path + ".substrate-managed.json"
	if BaseMarkerOwned(ctx, base, marker) {
		return true
	}
	dir := filepath.Dir(path)
	for dir != "." && dir != "/" {
		if BaseMarkerOwned(ctx, base, filepath.Join(dir, ".substrate-managed.json")) {
			return true
		}
		dir = filepath.Dir(dir)
	}
	return false
}

func DirtyPathSeedable(ctx context.Context, base, path string, profiles []string) bool {
	if fi, err := os.Lstat(path); err == nil {
		if fi.Mode()&os.ModeSymlink != 0 {
			return false
		}
	}

	switch path {
	case "substrate.json", ".claude/settings.json", ".omp/lsp.json", "justfile", "Makefile", "docs/jj-workflow.md":
		return true
	}

	if strings.HasPrefix(path, ".github/workflows/") {
		result, err := xshell.Run(ctx, "git", "show", base+":"+path)
		if err == nil && result.Code == 0 {
			first, _, _ := strings.Cut(string(result.Stdout), "\n")
			return first != "# substrate-managed"
		}
		return true
	}

	for _, prefix := range []string{".claude/skills/", ".omp/skills/", ".claude/agents/", ".omp/agents/"} {
		if strings.HasPrefix(path, prefix) {
			return !DirtyPathRepairable(ctx, base, path)
		}
	}

	for _, p := range profiles {
		dir, err := profileDir(p, "")
		if err != nil {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, "profile.json"))
		if err != nil {
			continue
		}
		var profile struct {
			Templates []struct {
				Dest string `json:"dest"`
			} `json:"templates"`
		}
		if err := json.Unmarshal(data, &profile); err != nil {
			continue
		}
		for _, t := range profile.Templates {
			if path == t.Dest {
				return true
			}
		}
	}

	return false
}

func AppliedPathAuthorized(ctx context.Context, stablePath, base, path string) bool {
	data, err := os.ReadFile(stablePath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "applied-path-authorized: read stable receipt: %v\n", err)
		return false
	}

	var receipt Receipt
	if err := json.Unmarshal(data, &receipt); err != nil {
		fmt.Fprintf(os.Stderr, "applied-path-authorized: parse receipt: %v\n", err)
		return false
	}

	if receipt.Repository.Status != StatusApplied {
		return false
	}

	fromRev := ""
	if receipt.Repository.FromRevision != nil {
		fromRev = *receipt.Repository.FromRevision
	}
	if fromRev != base {
		return false
	}

	for _, unit := range receipt.Repository.Units {
		if path != unit.Path && !strings.HasPrefix(path, unit.Path+"/") {
			continue
		}
		state, err := PathState(unit.Path)
		if err != nil {
			return false
		}
		return state == unit.Desired
	}

	return false
}
