package gate

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type langmapEntry struct {
	Profile string `json:"profile"`
	AstLang string `json:"ast_lang"`
	Mode    string `json:"mode"`
}

type langmapFile struct {
	Extensions map[string]json.RawMessage `json:"-"`
	Shebang    []shebangRow               `json:"__shebang__"`
	Raw        map[string]json.RawMessage
}

type shebangRow struct {
	Match []string        `json:"match"`
	Entry json.RawMessage `json:"entry"`
}

func BuildClaims(repoRoot, langmapPath, configPath, inventoryPath, claimsOut string) (string, error) {
	langmap, err := loadLangmap(langmapPath)
	if err != nil {
		return "", fmt.Errorf("claims: %w", err)
	}

	extMap := make(map[string]langmapEntry)
	for ext, raw := range langmap.Raw {
		var e langmapEntry
		if err := json.Unmarshal(raw, &e); err != nil {
			continue
		}
		extMap[ext] = e
	}

	var shebangRows []struct {
		Interps []string
		Entry   json.RawMessage
	}
	for _, sb := range langmap.Shebang {
		var e langmapEntry
		if err := json.Unmarshal(sb.Entry, &e); err != nil {
			continue
		}
		shebangRows = append(shebangRows, struct {
			Interps []string
			Entry   json.RawMessage
		}{Interps: sb.Match, Entry: sb.Entry})
	}

	scopesActive := scopesActive(configPath)

	f, err := os.Open(inventoryPath)
	if err != nil {
		return "", fmt.Errorf("claims: open inventory: %w", err)
	}
	defer f.Close()

	rawFile, err := os.CreateTemp("", "substrate-claims-raw-*")
	if err != nil {
		return "", fmt.Errorf("claims: create temp: %w", err)
	}
	rawName := rawFile.Name()
	defer os.Remove(rawName)

	w := bufio.NewWriter(rawFile)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		path := scanner.Text()
		if strings.ContainsRune(path, 0x1F) {
			rawFile.Close()
			return "", fmt.Errorf("claims: 0x1F byte in path — cannot emit to CLAIMS: %s", render1F(path))
		}
		ext := filepath.Ext(path)
		entry, ok := extMap[ext]
		if !ok {
			if s, err := os.Stat(filepath.Join(repoRoot, path)); err == nil && !s.IsDir() {
				interp := shebangInterp(filepath.Join(repoRoot, path))
				if interp != "" {
					for _, sb := range shebangRows {
						for _, m := range sb.Interps {
							if m == interp {
								json.Unmarshal(sb.Entry, &entry)
								ok = true
								break
							}
						}
						if ok {
							break
						}
					}
				}
			}
		}
		if !ok {
			continue
		}
		if scopesActive && !scopeAllows(path, entry.Profile, repoRoot, configPath) {
			continue
		}
		entryJSON, err := json.Marshal(entry)
		if err != nil {
			continue
		}
		if _, err := fmt.Fprintf(w, "%s\t%s\n", path, string(entryJSON)); err != nil {
			w.Flush()
			rawFile.Close()
			return "", fmt.Errorf("claims: write raw: %w", err)
		}
	}
	if err := w.Flush(); err != nil {
		rawFile.Close()
		return "", fmt.Errorf("claims: flush raw: %w", err)
	}
	if err := rawFile.Close(); err != nil {
		return "", fmt.Errorf("claims: close raw: %w", err)
	}

	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("claims: read inventory: %w", err)
	}

	claimsFile, err := os.CreateTemp("", "substrate-claims-*")
	if err != nil {
		return "", fmt.Errorf("claims: create temp: %w", err)
	}
	claimsName := claimsFile.Name()

	rawData, err := os.ReadFile(rawName)
	if err != nil {
		claimsFile.Close()
		os.Remove(claimsName)
		return "", fmt.Errorf("claims: read raw: %w", err)
	}

	cw := bufio.NewWriter(claimsFile)
	for _, line := range strings.Split(strings.TrimSuffix(string(rawData), "\n"), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 {
			continue
		}
		var entry langmapEntry
		if err := json.Unmarshal([]byte(parts[1]), &entry); err != nil {
			continue
		}
		if _, err := fmt.Fprintf(cw, "%s\x1f%s\x1f%s\x1f%s\x1f%s\n",
			parts[0], entry.Profile, entry.AstLang, entry.Mode, parts[1]); err != nil {
			cw.Flush()
			claimsFile.Close()
			os.Remove(claimsName)
			return "", fmt.Errorf("claims: write table: %w", err)
		}
	}
	if err := cw.Flush(); err != nil {
		claimsFile.Close()
		os.Remove(claimsName)
		return "", fmt.Errorf("claims: flush table: %w", err)
	}
	if err := claimsFile.Close(); err != nil {
		os.Remove(claimsName)
		return "", fmt.Errorf("claims: close table: %w", err)
	}

	if claimsOut != "" {
		if err := stagedMove(claimsName, claimsOut); err != nil {
			return "", fmt.Errorf("claims: capture to %s: %w", claimsOut, err)
		}
	}

	return claimsName, nil
}

func loadLangmap(path string) (*langmapFile, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read langmap: %w", err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("parse langmap: %w", err)
	}
	lf := &langmapFile{Raw: raw}
	if shebangRaw, ok := raw["__shebang__"]; ok {
		json.Unmarshal(shebangRaw, &lf.Shebang)
		delete(lf.Raw, "__shebang__")
	}
	return lf, nil
}

func shebangInterp(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	line, err := bufio.NewReader(f).ReadString('\n')
	if err != nil && line == "" {
		return ""
	}
	line = strings.TrimSpace(line)
	if !strings.HasPrefix(line, "#!") {
		return ""
	}
	interp := strings.TrimPrefix(line, "#!")
	parts := strings.Fields(strings.TrimSpace(interp))
	if len(parts) == 0 {
		return ""
	}
	name := filepath.Base(parts[0])
	if name == "env" && len(parts) > 1 {
		name = filepath.Base(parts[1])
	}
	return name
}

func scopesActive(configPath string) bool {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return false
	}
	var cfg struct {
		Scopes map[string]interface{} `json:"scopes"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return false
	}
	return len(cfg.Scopes) > 0
}

type scopeEntry struct {
	Profiles []string `json:"profiles"`
}

func scopeAllows(path, profile, repoRoot, configPath string) bool {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return true
	}
	var cfg struct {
		Scopes map[string]scopeEntry `json:"scopes"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return true
	}
	restricted := false
	for scopePath, entry := range cfg.Scopes {
		if strings.HasPrefix(path, scopePath) {
			restricted = true
			for _, p := range entry.Profiles {
				if p == profile {
					return true
				}
			}
		}
	}
	return !restricted
}

func render1F(path string) string {
	var b strings.Builder
	for _, r := range path {
		if r == 0x1F {
			b.WriteString("\\x1F")
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func stagedMove(src, dst string) error {
	info, err := os.Stat(dst)
	mode := os.FileMode(0600)
	if err == nil {
		mode = info.Mode()
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), filepath.Base(dst)+".*")
	if err != nil {
		return fmt.Errorf("stage temp: %w", err)
	}
	tmpName := tmp.Name()
	data, err := os.ReadFile(src)
	if err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return fmt.Errorf("read src: %w", err)
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return fmt.Errorf("write staged: %w", err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("close staged: %w", err)
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("chmod staged: %w", err)
	}
	if err := os.Rename(tmpName, dst); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("rename staged: %w", err)
	}
	return nil
}
