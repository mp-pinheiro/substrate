package gate

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func BuildInventory(repoRoot, subDir, fileListEnv string) (string, error) {
	configPath := filepath.Join(repoRoot, "substrate.json")
	inventory, err := os.CreateTemp("", "substrate-inventory-*")
	if err != nil {
		return "", fmt.Errorf("inventory: create temp: %w", err)
	}
	name := inventory.Name()

	if fileListEnv != "" {
		data, err := os.ReadFile(fileListEnv)
		if err != nil {
			inventory.Close()
			os.Remove(name)
			return "", fmt.Errorf("inventory: cannot read SUBSTRATE_FILE_LIST (%s)", fileListEnv)
		}
		if _, err := inventory.Write(data); err != nil {
			inventory.Close()
			os.Remove(name)
			return "", fmt.Errorf("inventory: write: %w", err)
		}
		if err := inventory.Close(); err != nil {
			os.Remove(name)
			return "", fmt.Errorf("inventory: close: %w", err)
		}
		info, err := os.Stat(name)
		if err != nil || info.Size() == 0 {
			os.Remove(name)
			return "", fmt.Errorf("inventory: SUBSTRATE_FILE_LIST is empty — a scoped gate over nothing cannot pass blind")
		}
		return name, nil
	}

	mode := cfgString(configPath, ".inventory")
	if mode == "auto" || mode == "" {
		if _, err := os.Stat(filepath.Join(repoRoot, ".jj")); err == nil {
			mode = "jj"
		} else {
			mode = "git"
		}
	}

	var cmd *exec.Cmd
	switch mode {
	case "jj":
		cmd = exec.Command("jj", "file", "list", "-T", "path ++ \"\\0\"")
		cmd.Dir = repoRoot
	case "git":
		cmd = exec.Command("git", "ls-files", "-z")
		cmd.Dir = repoRoot
	default:
		inventory.Close()
		os.Remove(name)
		return "", fmt.Errorf("inventory: unknown inventory mode: %s", mode)
	}

	out, err := cmd.Output()
	if err != nil {
		inventory.Close()
		os.Remove(name)
		return "", fmt.Errorf("inventory: %s failed: %w", mode, err)
	}

	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	scanner.Split(scanNUL)
	w := bufio.NewWriter(inventory)
	for scanner.Scan() {
		f := scanner.Text()
		info, err := os.Stat(filepath.Join(repoRoot, f))
		if err != nil || info.IsDir() {
			continue
		}
		if _, err := w.WriteString(f); err != nil {
			w.Flush()
			inventory.Close()
			os.Remove(name)
			return "", fmt.Errorf("inventory: write: %w", err)
		}
		if err := w.WriteByte('\n'); err != nil {
			w.Flush()
			inventory.Close()
			os.Remove(name)
			return "", fmt.Errorf("inventory: write: %w", err)
		}
	}
	if err := w.Flush(); err != nil {
		inventory.Close()
		os.Remove(name)
		return "", fmt.Errorf("inventory: flush: %w", err)
	}
	if err := inventory.Close(); err != nil {
		os.Remove(name)
		return "", fmt.Errorf("inventory: close: %w", err)
	}

	info, err := os.Stat(name)
	if err != nil || info.Size() == 0 {
		os.Remove(name)
		return "", fmt.Errorf("inventory: inventory is empty — wrong directory, or VCS not initialized")
	}
	return name, nil
}

func scanNUL(data []byte, atEOF bool) (advance int, token []byte, err error) {
	for i := 0; i < len(data); i++ {
		if data[i] == 0 {
			return i + 1, data[:i], nil
		}
	}
	if atEOF && len(data) > 0 {
		return len(data), data, nil
	}
	return 0, nil, nil
}

func cfgString(configPath, key string) string {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return ""
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return ""
	}
	parts := strings.Split(key, ".")
	v := interface{}(cfg)
	for _, p := range parts {
		m, ok := v.(map[string]interface{})
		if !ok {
			return ""
		}
		v = m[p]
	}
	s, _ := v.(string)
	return s
}

func cfgJSON(configPath, key string) string {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return "null"
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return "null"
	}
	parts := strings.Split(key, ".")
	v := interface{}(cfg)
	for _, p := range parts {
		m, ok := v.(map[string]interface{})
		if !ok {
			return "null"
		}
		v = m[p]
	}
	b, err := json.Marshal(v)
	if err != nil {
		return "null"
	}
	return string(b)
}
