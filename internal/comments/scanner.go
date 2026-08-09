package comments

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/config"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

type Scanner struct {
	cfg         *config.Config
	sgArgs      []string
	allowTagsRe *regexp.Regexp
}

func NewScanner(cfg *config.Config) *Scanner {
	s := &Scanner{cfg: cfg, allowTagsRe: buildAllowTagsRegex(cfg)}
	switch {
	case xshell.Have("ast-grep"):
		s.sgArgs = []string{"ast-grep"}
	case xshell.Have("bunx"):
		s.sgArgs = []string{"bunx", "--yes", "@ast-grep/cli@0.45.0"}
	}
	return s
}

type scanJob struct {
	path  string
	entry config.LangEntry
}

type scanState struct {
	proseRun           int
	proseStart         int
	codeSeen           bool
	runExempt          bool
	prevFullline       bool
	lastCodeWasFuncdef bool
}

func (s *Scanner) ScanFiles(ctx context.Context, lm *config.LangMap, paths []string) ([]Finding, error) {
	jobs := s.collectJobs(lm, paths)
	if len(jobs) == 0 {
		return nil, nil
	}
	astSet, err := s.extractAST(ctx, jobs)
	if err != nil {
		return nil, err
	}
	bundles := map[string]*regexBundle{}
	var findings []Finding
	for _, j := range jobs {
		fs, scanErr := s.scanOneFile(j.path, j.path, j.entry, astSet, bundles)
		if scanErr != nil {
			return nil, scanErr
		}
		findings = append(findings, fs...)
	}
	return findings, nil
}

func (s *Scanner) collectJobs(lm *config.LangMap, paths []string) []scanJob {
	var jobs []scanJob
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		entry, ok := lm.EntryFor(p)
		if !ok || !s.cfg.ScopeAllows(p, entry.Profile) {
			continue
		}
		jobs = append(jobs, scanJob{path: p, entry: entry})
	}
	return jobs
}

func (s *Scanner) ScanReader(ctx context.Context, lm *config.LangMap, name string, r io.Reader) ([]Finding, error) {
	entry, ok := lm.EntryFor(name)
	if !ok || !s.cfg.ScopeAllows(name, entry.Profile) {
		return nil, nil
	}
	content, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("comments: read stdin %s: %w", name, err)
	}

	ext := ""
	if strings.Contains(filepath.Base(name), ".") {
		if idx := strings.LastIndexByte(name, '.'); idx >= 0 {
			ext = name[idx:]
		}
	}
	tmp, err := os.CreateTemp("", "substrate-comments-stdin-*"+ext)
	if err != nil {
		return nil, fmt.Errorf("comments: create stdin tmp file: %w", err)
	}
	tmpPath := tmp.Name()
	defer func() { _ = os.Remove(tmpPath) }()
	if _, err := tmp.Write(content); err != nil {
		_ = tmp.Close()
		return nil, fmt.Errorf("comments: write stdin tmp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return nil, fmt.Errorf("comments: close stdin tmp file: %w", err)
	}

	astSet, err := s.extractAST(ctx, []scanJob{{path: tmpPath, entry: entry}})
	if err != nil {
		return nil, err
	}
	return s.scanOneFile(tmpPath, name, entry, astSet, map[string]*regexBundle{})
}

func bundleFor(cache map[string]*regexBundle, markers []string) (*regexBundle, error) {
	key := markersAlt(markers)
	if b, ok := cache[key]; ok {
		return b, nil
	}
	b, err := buildBundle(markers)
	if err != nil {
		return nil, err
	}
	cache[key] = b
	return b, nil
}

func (s *Scanner) scanOneFile(path, name string, entry config.LangEntry, astSet map[string]map[int]bool, bundles map[string]*regexBundle) ([]Finding, error) {
	if entry.Mode == "exempt" {
		return nil, nil
	}
	bundle, err := bundleFor(bundles, entry.Markers)
	if err != nil {
		return nil, err
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("comments: read %s: %w", path, err)
	}

	var lm *lmState
	if entry.Mode != "ast" {
		lm = newLMState(entry)
	}
	fileComments := astSet[path]

	st := &scanState{}
	var findings []Finding
	for i, line := range splitBashLines(content) {
		lineno := i + 1
		comment, fromBlock := extractComment(entry.Mode, line, lineno, fileComments, lm)

		if comment != "" && isExempt(comment, s.allowTagsRe) {
			st.proseRun = 0
			st.prevFullline = true
			continue
		}

		fullline := computeFullline(entry, lm, bundle, line, comment)

		if !fullline && hasNonSpace(line) {
			st.codeSeen = true
			st.lastCodeWasFuncdef = funcdefRegex.MatchString(line)
		}

		if comment != "" {
			if f, ok := classify(name, lineno, line, comment, fromBlock, entry.Markers, bundle, fullline, st.prevFullline); ok {
				findings = append(findings, f)
			}
		}

		findings = updateProseRun(st, findings, name, lineno, fullline, comment)
		st.prevFullline = fullline
	}
	return findings, nil
}

func extractComment(mode, line string, lineno int, fileComments map[int]bool, lm *lmState) (string, bool) {
	if mode == "ast" {
		if fileComments[lineno] {
			return line, false
		}
		return "", false
	}
	return lm.scan(line)
}

func computeFullline(entry config.LangEntry, lm *lmState, bundle *regexBundle, line, comment string) bool {
	if comment == "" {
		return false
	}
	if entry.Mode == "ast" {
		return bundle.fullLineAST.MatchString(line)
	}
	trimmedLine := trimLeadingSpace(line)
	trimmedComment := trimLeadingSpace(comment)
	if trimmedLine == trimmedComment {
		return true
	}
	if bundle.fullLineLM.MatchString(trimmedLine) {
		return true
	}
	return lm.bo != "" && strings.HasPrefix(trimmedLine, lm.bo)
}

func classify(name string, lineno int, line, comment string, fromBlock bool, markers []string, bundle *regexBundle, fullline, prevFullline bool) (Finding, bool) {
	ctext := comment
	if fromBlock && len(markers) > 0 {
		ctext = markers[0] + " " + trimLeadingSpace(comment)
	}
	lower := strings.ToLower(ctext)

	switch {
	case bundle.banner.MatchString(lower) || bannerFallbackRegex.MatchString(lower):
		return Finding{Name: name, Line: lineno, Rule: "banner", Text: line}, true
	case bundle.todo.MatchString(lower):
		return Finding{Name: name, Line: lineno, Rule: "todo-chatter", Text: line}, true
	case !fullline || !prevFullline:
		for i, pat := range bundle.patterns {
			if !pat.MatchString(lower) {
				continue
			}
			if patternNames[i] == "restates-code" && causalRegex.MatchString(lower) {
				continue
			}
			return Finding{Name: name, Line: lineno, Rule: patternNames[i], Text: line}, true
		}
	}
	return Finding{}, false
}

func updateProseRun(st *scanState, findings []Finding, name string, lineno int, fullline bool, comment string) []Finding {
	if !fullline || !hasAlnum(comment) {
		st.proseRun = 0
		return findings
	}
	if st.proseRun == 0 {
		st.proseStart = lineno
		st.runExempt = !st.codeSeen || st.lastCodeWasFuncdef
	}
	st.proseRun++
	if st.proseRun == 3 && !st.runExempt {
		findings = append(findings, Finding{
			Name: name, Line: st.proseStart, Rule: "prose-block",
			Text: "3+ consecutive comment lines starting here",
		})
	}
	return findings
}
