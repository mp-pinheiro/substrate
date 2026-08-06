package config

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type LangEntry struct {
	Mode    string      `json:"mode"`
	ASTLang string      `json:"ast_lang"`
	Markers []string    `json:"markers"`
	Block   [][2]string `json:"block"`
	Heredoc bool        `json:"heredoc"`
	Profile string      `json:"profile"`
}

type shebangRule struct {
	match []string
	entry LangEntry
}

type LangMap struct {
	byExt   map[string]LangEntry
	shebang []shebangRule
}

type shebangRuleJSON struct {
	Match []string  `json:"match"`
	Entry LangEntry `json:"entry"`
}

func LoadLangMap(path string) (*LangMap, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: read langmap %s: %w", path, err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("config: parse langmap %s: %w", path, err)
	}

	lm := &LangMap{byExt: make(map[string]LangEntry, len(raw))}
	if sb, ok := raw["__shebang__"]; ok {
		var rules []shebangRuleJSON
		if err := json.Unmarshal(sb, &rules); err != nil {
			return nil, fmt.Errorf("config: parse langmap shebang table %s: %w", path, err)
		}
		lm.shebang = make([]shebangRule, 0, len(rules))
		for _, r := range rules {
			lm.shebang = append(lm.shebang, shebangRule{match: r.Match, entry: r.Entry})
		}
		delete(raw, "__shebang__")
	}
	for ext, val := range raw {
		var entry LangEntry
		if err := json.Unmarshal(val, &entry); err != nil {
			return nil, fmt.Errorf("config: parse langmap entry %s in %s: %w", ext, path, err)
		}
		lm.byExt[ext] = entry
	}
	return lm, nil
}

func (m *LangMap) EntryForExt(ext string) (LangEntry, bool) {
	e, ok := m.byExt[ext]
	return e, ok
}

func (m *LangMap) EntryForInterpreter(interp string) (LangEntry, bool) {
	for _, r := range m.shebang {
		for _, want := range r.match {
			if want == interp {
				return r.entry, true
			}
		}
	}
	return LangEntry{}, false
}

func (m *LangMap) EntryFor(path string) (LangEntry, bool) {
	if e, ok := m.byExt[extOf(path)]; ok {
		return e, true
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return LangEntry{}, false
	}
	interp, ok := shebangInterp(path)
	if !ok {
		return LangEntry{}, false
	}
	return m.EntryForInterpreter(interp)
}

func extOf(path string) string {
	idx := strings.LastIndexByte(path, '.')
	if idx < 0 {
		return "." + path
	}
	return path[idx:]
}

func shebangInterp(path string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer func() { _ = f.Close() }()

	line, _ := bufio.NewReader(f).ReadString('\n')
	line = strings.TrimSuffix(line, "\n")
	if !strings.HasPrefix(line, "#!") {
		return "", false
	}

	fields := strings.Fields(line[len("#!"):])
	var first, second string
	if len(fields) > 0 {
		first = fields[0]
	}
	if len(fields) > 1 {
		second = fields[1]
	}
	interp := baseName(first)
	if interp == "env" {
		interp = baseName(second)
	}
	return interp, true
}

func baseName(s string) string {
	if s == "" {
		return ""
	}
	return filepath.Base(s)
}
