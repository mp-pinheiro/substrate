package policy

import (
	"os"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/bashglob"
	"github.com/mp-pinheiro/substrate/internal/config"
)

// WHY: cfg is nil when substrate.json exists but failed to parse — the
// caller signals corrupt config this way since LoadConfig has no other channel.
func ProtectPaths(in Input, cfg *config.Config, repoRoot string) Decision {
	path := in.FilePath
	if path == "" {
		return Decision{}
	}
	if cfg == nil {
		return block("blocked: substrate.json is corrupt — fix it before writing anything else\n")
	}
	if cfg.Present && !cfg.ContractsValid() {
		return block("blocked: substrate.json contracts entries need name/regen/paths — fix the config\n")
	}

	abs := path
	if !strings.HasPrefix(abs, "/") {
		abs = repoRoot + "/" + abs
	}

	if info, err := os.Lstat(abs); err == nil && info.Mode()&os.ModeSymlink != 0 {
		target, ok := readlinkF(abs)
		if !ok {
			if t, rerr := os.Readlink(abs); rerr == nil {
				target = t
			} else {
				target = ""
			}
		}
		return block("blocked: %s is a symlink to %s — writing through it clobbers the target; edit the target explicitly if that is intended\n", path, target)
	}

	rel := path
	if strings.HasPrefix(rel, repoRoot+"/") {
		rel = strings.TrimPrefix(rel, repoRoot+"/")
	}

	real, ok := readlinkF(abs)
	if !ok {
		real = abs
	}
	switch {
	case strings.HasPrefix(real, repoRoot+"/"):
		real = strings.TrimPrefix(real, repoRoot+"/")
	case real == repoRoot:
		real = "."
	default:
		return block("blocked: %s resolves outside the repo (%s) — a parent directory is a symlink\n", path, real)
	}

	if d, blocked := checkHard(rel); blocked {
		return d
	}
	if d, blocked := checkHard(real); blocked {
		return d
	}

	if !cfg.Present {
		return Decision{}
	}
	for _, g := range cfg.ProtectedPaths {
		if g == "" {
			continue
		}
		if bashglob.Match(g, rel) {
			return block("blocked: %s is protected by substrate.json protected_paths\n", rel)
		}
		if bashglob.Match(g, real) {
			return block("blocked: %s is protected by substrate.json protected_paths\n", real)
		}
	}
	for _, c := range cfg.Contracts {
		for _, g := range c.Paths {
			if g == "" {
				continue
			}
			for _, candidate := range [2]string{rel, real} {
				if candidate == g || strings.HasPrefix(candidate, g+"/") {
					return block("blocked: %s is generated from a contract — edit the contract source; the gate regenerates (substrate.json contracts)\n", candidate)
				}
			}
		}
	}
	return Decision{}
}

func checkHard(name string) (Decision, bool) {
	switch {
	case bashglob.Match("substrate-baseline.json", name):
		return block("blocked: baseline changes only via the gate (--update-baseline)\n"), true
	case bashglob.Match("*/substrate-baseline.json", name):
		return block("blocked: %s is not the repo baseline, but that basename is governed anywhere in the tree — the rule is name-based so it can rule on paths whose parents do not exist yet; rename the file if it is not a substrate baseline\n", name), true
	case bashglob.Match(".substrate/*", name), bashglob.Match("*/.substrate/*", name):
		return block("blocked: %s is vendored substrate core — change the kit and run: substrate update\n", name), true
	case bashglob.Match("CLAUDE.md", name), bashglob.Match("*/CLAUDE.md", name):
		return block("blocked: CLAUDE.md is the governance doc — propose the edit to the user instead\n"), true
	}
	return Decision{}, false
}
