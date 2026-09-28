package policy

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/bashglob"
	"github.com/mp-pinheiro/substrate/internal/config"
)

// WHY: cfg is nil when substrate.json exists but failed to parse — the
// caller signals corrupt config this way since LoadConfig has no other channel.
func ProtectPaths(in Input, cfg *config.Config, repoRoot string) Decision {
	path := in.FilePath
	if path == "" {
		return allow()
	}
	if cfg == nil {
		return block("blocked: substrate.json is corrupt — fix it before writing anything else\n")
	}
	if cfg.Present && !cfg.ContractsValid() {
		return block("blocked: substrate.json contracts entries need name/regen/paths — fix the config\n")
	}

	abs := filepath.Clean(path)
	if !strings.HasPrefix(abs, "/") {
		abs = filepath.Clean(repoRoot + "/" + abs)
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

	rel := filepath.Clean(path)
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

	if d, hit := hardRule(rel); hit {
		return d
	}
	if d, hit := hardRule(real); hit {
		return d
	}
	if cfg.Present {
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
	}
	for _, candidate := range [2]string{rel, real} {
		if d, hit := askRule(candidate, cfg); hit {
			return d
		}
	}
	return allow()
}

func CheckpointDecision(name string, cfg *config.Config) Decision {
	if d, hit := hardRule(name); hit {
		return d
	}
	if d, hit := askRule(name, cfg); hit {
		return d
	}
	return allow()
}

func hardRule(name string) (Decision, bool) {
	switch {
	case bashglob.Match("substrate-baseline.json", name):
		return block("blocked: baseline changes are checkpoint/baseline-transaction owned; use the sanctioned checkpoint workflow\n"), true
	case bashglob.Match("*/substrate-baseline.json", name):
		return block("blocked: %s is a governed baseline path; use the sanctioned checkpoint workflow\n", name), true
	case bashglob.Match("substrate.json", name):
		return block("blocked: substrate.json contains human-approved policy — present the policy change to the user\n"), true
	case bashglob.Match(".substrate/*", name), bashglob.Match("*/.substrate/*", name):
		return block("blocked: %s is vendored substrate core — change the kit source, then the user runs substrate update --apply --checkpoint; never commit the mirror directly\n", name), true
	}
	return allow(), false
}

var agentInstructionFiles = [...]string{"CLAUDE.md", "AGENTS.md"}

func askRule(name string, cfg *config.Config) (Decision, bool) {
	for _, base := range agentInstructionFiles {
		if bashglob.Match(base, name) || bashglob.Match("*/"+base, name) {
			return ask("%s holds agent instructions. Approve only after reviewing the change; the checkpoint leaves it for you to commit.", name), true
		}
	}
	if cfg == nil || !cfg.Present {
		return allow(), false
	}
	for _, g := range cfg.AskPaths {
		if g != "" && bashglob.Match(g, name) {
			return ask("%s is listed in substrate.json ask_paths. Approve only after reviewing the change; the checkpoint leaves it for you to commit.", name), true
		}
	}
	return allow(), false
}
