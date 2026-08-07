package receipt

import (
	"fmt"
	"io/fs"
	"path/filepath"
	"strings"
)

var configurationNameSet = map[string]bool{
	".gitleaks.toml": true, ".gitleaksignore": true, ".jscpd.json": true, ".jscpdrc": true,
	".shellcheckrc": true, "ruff.toml": true, ".ruff.toml": true, "pyproject.toml": true,
	"setup.cfg": true, ".importlinter": true, ".golangci.yml": true, ".golangci.yaml": true,
	".stylua.toml": true, ".luacheckrc": true, ".sqlfluff": true, ".tflint.hcl": true,
	"tsconfig.json": true, ".dependency-cruiser.cjs": true, "svelte.config.js": true,
	"dbt_project.yml": true, "go.mod": true, "go.sum": true, "package.json": true,
	"bun.lock": true, "bun.lockb": true, "package-lock.json": true, "pnpm-lock.yaml": true,
	"yarn.lock": true, "compile_commands.json": true, ".clang-tidy": true,
	".terraform.lock.hcl": true, "actionlint.yaml": true, "actionlint.yml": true,
}

var configurationSeedNames = []string{
	"substrate.json", "substrate-baseline.json", ".gitleaks.toml", ".gitleaksignore",
	".jscpd.json", ".jscpdrc", ".shellcheckrc",
}

func computeConfigurationHash(repoRoot string, profiles []string) (string, error) {
	paths := append([]string(nil), configurationSeedNames...)

	for _, p := range profiles {
		dests, err := profileTemplateDests(repoRoot, p)
		if err != nil {
			return "", err
		}
		paths = append(paths, dests...)
	}

	walked, err := walkConfigurationCandidates(repoRoot)
	if err != nil {
		return "", err
	}
	paths = append(paths, walked...)

	// WHY: bash hashed "./x" and "x" as two files (H4); one spelling before dedupe is a deliberate digest change.
	for i, p := range paths {
		paths[i] = strings.TrimPrefix(p, "./")
	}
	paths = dedupeSort(paths)

	return hashItems(paths, func(rel string) ([]byte, error) {
		return fileStateRecord(repoRoot, rel)
	})
}

// walkConfigurationCandidates must track bash's find in core/receipt-lib.sh; one-sided names split the digest.
func walkConfigurationCandidates(repoRoot string) ([]string, error) {
	var out []string
	err := filepath.WalkDir(repoRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("receipt: walk %s: %w", path, err)
		}
		if path == repoRoot {
			return nil
		}
		rel, relErr := relSlash(repoRoot, path)
		if relErr != nil {
			return relErr
		}

		if d.IsDir() {
			if rel == ".git" || rel == ".jj" || rel == ".substrate" || d.Name() == "node_modules" {
				return fs.SkipDir
			}
			return nil
		}
		if d.Type()&fs.ModeSymlink == 0 && !d.Type().IsRegular() {
			return nil
		}
		if configurationNameSet[d.Name()] {
			out = append(out, rel)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("receipt: walk %s: %w", repoRoot, err)
	}
	return out, nil
}
