package gate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Preflight struct {
	SubDir    string
	RepoRoot  string
	Config    string
	Langmap   string
	Baseline  string
	Flags     PreflightFlags
}

type PreflightFlags struct {
	UpdateBaseline   bool
	TightenBaseline  bool
	AcceptRegression bool
	AcceptKeys       string
	AcceptReason     string
}

func ResolveRoots() (subDir, repoRoot string, err error) {
	subDir = os.Getenv("SUBSTRATE_DIR")
	repoRoot = os.Getenv("REPO_ROOT")
	if subDir != "" && repoRoot != "" {
		return subDir, repoRoot, nil
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", "", fmt.Errorf("getwd: %w", err)
	}
	dir := cwd
	for {
		versionPath := filepath.Join(dir, ".substrate", "VERSION")
		if _, err := os.Stat(versionPath); err == nil {
			repoRoot = dir
			subDir = filepath.Join(dir, ".substrate")
			return subDir, repoRoot, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", "", fmt.Errorf(".substrate/VERSION not found from %s", cwd)
		}
		dir = parent
	}
}

func ParseFlags(args []string) (PreflightFlags, []string, error) {
	var f PreflightFlags
	var rest []string
	for _, a := range args {
		switch {
		case a == "--update-baseline":
			f.UpdateBaseline = true
		case a == "--tighten":
			f.UpdateBaseline = true
			f.TightenBaseline = true
		case a == "--accept-regression":
			f.UpdateBaseline = true
			f.AcceptRegression = true
		case strings.HasPrefix(a, "--accept-regression="):
			f.UpdateBaseline = true
			f.AcceptRegression = true
			f.AcceptKeys = strings.TrimPrefix(a, "--accept-regression=")
		case a == "--list-checks":
			rest = append(rest, a)
		case strings.HasPrefix(a, "--reason="):
			f.AcceptReason = strings.TrimPrefix(a, "--reason=")
		default:
			fmt.Fprintf(os.Stderr, "usage: %s [--update-baseline|--tighten|--accept-regression[=key1,key2]] [--reason=<text>]\n", os.Args[0])
			return f, nil, fmt.Errorf("unknown flag: %s", a)
		}
	}
	return f, rest, nil
}

func RunPreflight(p Preflight) int {
	if err := jsonValidFile(p.Config); err != nil {
		warn("substrate.json missing or corrupt — run: substrate init")
		return 12
	}
	if err := jsonValidFile(p.Langmap); err != nil {
		warn("%s missing or corrupt — run: substrate init (or update)", p.Langmap)
		return 12
	}
	if _, err := os.Stat(p.Baseline); err == nil {
		if err := jsonValidFile(p.Baseline); err != nil {
			warn("%s is corrupt — restore it from VCS or delete it and rerun --update-baseline", p.Baseline)
			return 12
		}
	}

	if p.Flags.AcceptRegression {
		if p.Flags.AcceptReason == "" {
			warn("accepting a regression requires --reason=<text> — record why the ceiling moves; it lands in substrate-baseline.json and is reviewed in the diff")
			return 12
		}
		if strings.ContainsAny(p.Flags.AcceptReason, ";&|<>$`\n") {
			warn("--reason must not contain ; & | < > $ ` or a newline — the checkpoint command guard rejects them and the reason is rendered in a markdown table")
			return 12
		}
		if len(p.Flags.AcceptReason) < 20 {
			warn("--reason must be at least 20 characters — state what grew and why the cheaper alternative is worse")
			return 12
		}
	} else if p.Flags.AcceptReason != "" {
		warn("--reason applies only to --accept-regression")
		return 12
	}
	return 0
}

func jsonValidFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	var v interface{}
	if err := json.Unmarshal(data, &v); err != nil {
		return fmt.Errorf("parse %s: %w", path, err)
	}
	return nil
}
