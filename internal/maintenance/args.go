package maintenance

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/vcs"
)

var convCommitRe = regexp.MustCompile(`^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?!?: [^[:space:]]`)

func profileDir(name string, kitRoot string) (string, error) {
	local := filepath.Join("substrate-profiles", name)
	if fi, err := os.Stat(local); err == nil && fi.IsDir() {
		return local, nil
	}
	kit := filepath.Join(kitRoot, "profiles", name)
	if fi, err := os.Stat(kit); err == nil && fi.IsDir() {
		return kit, nil
	}
	return "", fmt.Errorf("unknown profile: %s", name)
}

func loadProfileNames(configPath string) ([]string, error) {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("maintenance: read substrate.json: %w", err)
	}
	var cfg struct {
		Profiles []string `json:"profiles"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("maintenance: parse substrate.json: %w", err)
	}
	return cfg.Profiles, nil
}

func ParseArgs(args []string) (*Context, error) {
	if len(args) == 0 {
		return nil, fmt.Errorf("maintenance: missing operation")
	}
	ctx := &Context{
		Operation:    args[0],
		RequestedVCS: "auto",
	}
	args = args[1:]

	for len(args) > 0 {
		switch {
		case args[0] == "--profile":
			if len(args) < 2 {
				return nil, fmt.Errorf("--profile requires a value")
			}
			ctx.ProfileCSV = args[1]
			args = args[2:]
		case args[0] == "--vcs":
			if len(args) < 2 {
				return nil, fmt.Errorf("--vcs requires a value")
			}
			ctx.RequestedVCS = args[1]
			args = args[2:]
		case args[0] == "--force":
			ctx.Force = true
			args = args[1:]
		case args[0] == "--from-worktree":
			ctx.FromWorktree = true
			args = args[1:]
		case args[0] == "--apply":
			args = args[1:]
		case args[0] == "--checkpoint":
			ctx.Checkpoint = true
			args = args[1:]
		case args[0] == "--accept-baseline":
			ctx.AcceptBaseline = true
			args = args[1:]
		case args[0] == "--accept-regression":
			return nil, fmt.Errorf("--accept-regression requires the keyed form: --accept-regression=<metric>[,<metric>]")
		case strings.HasPrefix(args[0], "--accept-regression="):
			ctx.AcceptRegression = strings.TrimPrefix(args[0], "--accept-regression=")
			if ctx.AcceptRegression == "" {
				return nil, fmt.Errorf("--accept-regression= needs at least one metric")
			}
			args = args[1:]
		case args[0] == "--reason":
			if len(args) < 2 {
				return nil, fmt.Errorf("--reason requires a value")
			}
			ctx.AcceptReason = args[1]
			args = args[2:]
		case args[0] == "--message":
			if len(args) < 2 {
				return nil, fmt.Errorf("--message requires a value")
			}
			ctx.Message = args[1]
			args = args[2:]
		case args[0] == "--json":
			ctx.JSON = true
			args = args[1:]
		case args[0] == "--repo-only":
			ctx.RepoOnly = true
			args = args[1:]
		default:
			return nil, fmt.Errorf("unknown %s flag: %s", ctx.Operation, args[0])
		}
	}

	if ctx.AcceptRegression != "" && ctx.AcceptReason == "" {
		return nil, fmt.Errorf("--accept-regression requires --reason \"<text>\"")
	}
	if ctx.AcceptRegression == "" && ctx.AcceptReason != "" {
		return nil, fmt.Errorf("--reason applies only to --accept-regression")
	}

	switch ctx.RequestedVCS {
	case "auto", "git", "jj":
	default:
		return nil, fmt.Errorf("unknown --vcs value: %s", ctx.RequestedVCS)
	}

	var err error
	ctx.VCS, err = detectVCS()
	if err != nil {
		return nil, fmt.Errorf("maintenance: detect vcs: %w", err)
	}
	if ctx.RequestedVCS != "auto" && ctx.RequestedVCS != ctx.VCS {
		return nil, fmt.Errorf("requested VCS %s does not match active %s repository", ctx.RequestedVCS, ctx.VCS)
	}

	if ctx.ProfileCSV == "" {
		if ctx.Operation != OpUpdate {
			if _, err := os.Stat("substrate.json"); os.IsNotExist(err) {
				return nil, fmt.Errorf("%s requires --profile a,b", ctx.Operation)
			}
			profiles, err := loadProfileNames("substrate.json")
			if err != nil || len(profiles) == 0 {
				return nil, fmt.Errorf("%s requires a valid substrate.json", ctx.Operation)
			}
			ctx.ProfileCSV = strings.Join(profiles, ",")
		}
	}

	if ctx.ProfileCSV != "" {
		ctx.Profiles = []string{"base"}
		seen := map[string]bool{"base": true}
		for _, p := range strings.Split(ctx.ProfileCSV, ",") {
			p = strings.TrimSpace(p)
			if p == "" {
				continue
			}
			if seen[p] {
				continue
			}
			if _, err := profileDir(p, ""); err != nil {
				return nil, fmt.Errorf("unknown profile: %s", p)
			}
			ctx.Profiles = append(ctx.Profiles, p)
			seen[p] = true
		}
		if len(ctx.Profiles) <= 1 && ctx.ProfileCSV != "base" {
			return nil, fmt.Errorf("at least one profile is required")
		}
	}

	if ctx.Message == "" {
		switch ctx.Operation {
		case OpInit:
			ctx.Message = "chore(substrate): initialize"
		case OpBootstrap:
			ctx.Message = "chore(substrate): synchronize"
		case OpUpdate:
			ctx.Message = "chore(substrate): update engine"
		}
	}

	if ctx.Checkpoint {
		if !convCommitRe.MatchString(ctx.Message) {
			return nil, fmt.Errorf("checkpoint message must follow Conventional Commits: type(scope): subject")
		}
		if len(ctx.Message) > 50 {
			return nil, fmt.Errorf("checkpoint message exceeds 50 characters")
		}
	}

	return ctx, nil
}

func detectVCS() (string, error) {
	repo, err := vcs.Detect(".")
	if err != nil {
		return "", fmt.Errorf("maintenance: detect vcs: %w", err)
	}
	switch repo.Kind {
	case vcs.KindJJ:
		return "jj", nil
	case vcs.KindGit:
		return "git", nil
	default:
		return "git", nil
	}
}
