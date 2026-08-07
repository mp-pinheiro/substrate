package receipt

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/config"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

const RecipeVersion = 2

type State struct {
	Revision          string
	VCS               string
	RefsHash          string
	RepositoryHash    string
	EngineHash        string
	ToolchainHash     string
	ConfigurationHash string
	ExternalHash      string
}

// WHY: insertion order here must match MarshalSorted's key order — Write
// embeds this Doc() unsorted, so the two renderings stay byte-identical (C18).
func (s *State) Doc() *canonjson.Object {
	return canonjson.NewObject().
		Set("configurationHash", s.ConfigurationHash).
		Set("engineHash", s.EngineHash).
		Set("externalHash", s.ExternalHash).
		Set("recipeVersion", int64(RecipeVersion)).
		Set("refsHash", s.RefsHash).
		Set("repositoryHash", s.RepositoryHash).
		Set("revision", s.Revision).
		Set("toolchainHash", s.ToolchainHash).
		Set("vcs", s.VCS)
}

// WHY: bash pipes jq -cnS's LF-terminated output into sha256sum, so the digest
// covers the trailing byte (C18).
func Fingerprint(s *State) (string, error) {
	b, err := canonjson.MarshalSorted(s.Doc())
	if err != nil {
		return "", fmt.Errorf("receipt: marshal state: %w", err)
	}
	b = append(b, '\n')
	return xshell.SHA256Bytes(b), nil
}

type RefusalReason string

const (
	ReasonFileListScoped   RefusalReason = "file-list-scoped"
	ReasonConfigMissing    RefusalReason = "config-missing"
	ReasonConfigCorrupt    RefusalReason = "config-corrupt"
	ReasonContractsPresent RefusalReason = "contracts-present"
	ReasonJJUnresolvable   RefusalReason = "jj-unresolvable"
	ReasonWorkingCopyDirty RefusalReason = "working-copy-dirty"
)

// Refusal is gate_state_json's non-error outcome (C13): a deliberate
// non-reusable state, never a sentinel digest (H17).
type Refusal struct {
	Reason RefusalReason
}

func (r *Refusal) Error() string {
	return fmt.Sprintf("receipt: refused: %s", r.Reason)
}

func refuse(reason RefusalReason) error {
	return &Refusal{Reason: reason}
}

// BuildState reproduces gate_state_json (C13): bash's three refusals plus
// B5's jj-unresolvable refusal, evaluated in order, then the six hashers.
func BuildState(ctx context.Context, repoRoot string) (*State, error) {
	if os.Getenv("SUBSTRATE_FILE_LIST") != "" {
		return nil, refuse(ReasonFileListScoped)
	}

	cfg, err := config.LoadConfig(filepath.Join(repoRoot, "substrate.json"))
	if err != nil {
		return nil, refuse(ReasonConfigCorrupt)
	}
	if !cfg.Present {
		return nil, refuse(ReasonConfigMissing)
	}
	if !cfg.ContractsValid() || len(cfg.Contracts) > 0 {
		return nil, refuse(ReasonContractsPresent)
	}

	repo, err := detectBackend(repoRoot)
	if err != nil {
		return nil, err
	}

	clean, err := workingCopyClean(ctx, repo)
	if err != nil {
		return nil, fmt.Errorf("receipt: check working copy: %w", err)
	}
	if !clean {
		return nil, refuse(ReasonWorkingCopyDirty)
	}

	revision, revErrText, err := repo.Revision(ctx)
	if err != nil {
		return nil, fmt.Errorf("receipt: probe revision: %w", err)
	}
	if revErrText != "" {
		return nil, fmt.Errorf("receipt: probe revision: %s", revErrText)
	}

	refsHash, err := computeRefsHash(ctx, repo)
	if err != nil {
		return nil, err
	}
	repositoryHash, err := computeRepositoryHash(ctx, repo)
	if err != nil {
		return nil, err
	}
	engineHash, err := computeEngineHash(repoRoot)
	if err != nil {
		return nil, err
	}
	toolchainHash, err := computeToolchainHash(ctx, repo, cfg.Profiles)
	if err != nil {
		return nil, err
	}
	configurationHash, err := computeConfigurationHash(repoRoot, cfg.Profiles)
	if err != nil {
		return nil, err
	}
	externalHash, err := computeExternalHash()
	if err != nil {
		return nil, err
	}

	return &State{
		Revision:          revision,
		VCS:               string(repo.Kind),
		RefsHash:          refsHash,
		RepositoryHash:    repositoryHash,
		EngineHash:        engineHash,
		ToolchainHash:     toolchainHash,
		ConfigurationHash: configurationHash,
		ExternalHash:      externalHash,
	}, nil
}
