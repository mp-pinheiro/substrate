package comments

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/xshell"
)

type sgMatch struct {
	File  string `json:"file"`
	Range struct {
		Start struct {
			Line int `json:"line"`
		} `json:"start"`
	} `json:"range"`
}

func canonicalExt(lang string) string {
	switch lang {
	case "bash":
		return ".sh"
	case "typescript":
		return ".ts"
	case "javascript":
		return ".js"
	case "go":
		return ".go"
	case "lua":
		return ".lua"
	case "python":
		return ".py"
	case "cpp":
		return ".cpp"
	case "yaml":
		return ".yml"
	default:
		return ".txt"
	}
}

func (s *Scanner) extractAST(ctx context.Context, jobs []scanJob) (map[string]map[int]bool, error) {
	byLang := map[string][]string{}
	for _, j := range jobs {
		if j.entry.Mode != "ast" {
			continue
		}
		if j.entry.ASTLang == "" {
			return nil, infraErrf("langmap: ast mode without ast_lang for %s", j.path)
		}
		byLang[j.entry.ASTLang] = append(byLang[j.entry.ASTLang], j.path)
	}
	if len(byLang) == 0 {
		return nil, nil
	}
	if len(s.sgArgs) == 0 {
		return nil, infraErrf("comment gate: ast-grep unavailable (install ast-grep, or bun for bunx) — refusing to scan AST-mode files blind")
	}

	tmpdir, err := os.MkdirTemp("", "substrate-comments-")
	if err != nil {
		return nil, fmt.Errorf("comments: create ast-grep tmp dir: %w", err)
	}
	defer func() { _ = os.RemoveAll(tmpdir) }()

	set := map[string]map[int]bool{}
	for lang, files := range byLang {
		scanList, tmpmap, stageErr := stageASTFiles(tmpdir, lang, files)
		if stageErr != nil {
			return nil, stageErr
		}
		if len(scanList) == 0 {
			continue
		}
		matches, runErr := s.runASTGrep(ctx, lang, scanList)
		if runErr != nil {
			return nil, runErr
		}
		for _, m := range matches {
			path := m.File
			if orig, ok := tmpmap[path]; ok {
				path = orig
			}
			if set[path] == nil {
				set[path] = map[int]bool{}
			}
			set[path][m.Range.Start.Line+1] = true
		}
	}
	return set, nil
}

func stageASTFiles(tmpdir, lang string, files []string) ([]string, map[string]string, error) {
	scanList := make([]string, 0, len(files))
	tmpmap := map[string]string{}
	cext := canonicalExt(lang)
	for _, f := range files {
		if strings.Contains(filepath.Base(f), ".") {
			scanList = append(scanList, f)
			continue
		}
		t := filepath.Join(tmpdir, strings.ReplaceAll(f, "/", "_")+cext)
		if err := copyFile(f, t); err != nil {
			return nil, nil, infraErrf("comment gate: tmp copy failed for %s: %w", f, err)
		}
		tmpmap[t] = f
		scanList = append(scanList, t)
	}
	return scanList, tmpmap, nil
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return fmt.Errorf("comments: read %s: %w", src, err)
	}
	mode := fs.FileMode(0o644)
	if info, statErr := os.Stat(src); statErr == nil {
		mode = info.Mode().Perm()
	}
	if err := os.WriteFile(dst, data, mode); err != nil {
		return fmt.Errorf("comments: write %s: %w", dst, err)
	}
	return nil
}

func (s *Scanner) runASTGrep(ctx context.Context, lang string, files []string) ([]sgMatch, error) {
	rule := "id: c\nlanguage: " + lang + "\nrule: {kind: comment}"
	args := make([]string, 0, len(s.sgArgs)-1+4+len(files))
	args = append(args, s.sgArgs[1:]...)
	args = append(args, "scan", "--inline-rules", rule, "--json=compact")
	args = append(args, files...)

	res, err := xshell.Run(ctx, s.sgArgs[0], args...)
	if err != nil {
		return nil, infraErrf("comment gate: ast-grep extraction failed for %s — refusing to scan blind: %w", lang, err)
	}
	if res.Code != 0 {
		return nil, infraErrf("comment gate: ast-grep extraction failed for %s — refusing to scan blind", lang)
	}
	var matches []sgMatch
	if err := json.Unmarshal(res.Stdout, &matches); err != nil {
		return nil, infraErrf("comment gate: ast-grep extraction failed for %s — refusing to scan blind", lang)
	}
	return matches, nil
}
