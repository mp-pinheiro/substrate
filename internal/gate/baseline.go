package gate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func WriteBaseline(baselinePath, metricsOut, configPath string, flags PreflightFlags, acceptedNow []string) int {
	if flags.TightenBaseline {
		if _, err := os.Stat(baselinePath); os.IsNotExist(err) {
			warn("baseline absent — establish initial debt explicitly with: substrate baseline")
			return 1
		}
	}

	currentMetrics := make(map[string]Number)
	currentDir := make(map[string]string)

	data, err := os.ReadFile(metricsOut)
	if err != nil {
		warn("baseline: cannot read metrics: %v", err)
		return 1
	}

	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	for _, line := range lines {
		if line == "" {
			continue
		}
		var m struct {
			Name  string          `json:"name"`
			Value json.RawMessage `json:"value"`
			Dir   string          `json:"dir"`
		}
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			continue
		}
		if m.Name == "max_file_lines" {
			continue
		}
		if m.Dir != "" {
			currentDir[m.Name] = m.Dir
		}
		n, err := ParseNumber(m.Value)
		if err != nil {
			continue
		}
		currentMetrics[m.Name] = n
	}

	var newBaseline map[string]interface{}

	if flags.TightenBaseline || (flags.UpdateBaseline && fileExists(baselinePath)) || (flags.AcceptRegression && flags.AcceptKeys != "") {
		oldMetrics, oldDir, err := loadBaseline(baselinePath)
		if err != nil {
			warn("baseline: cannot load existing baseline: %v", err)
			return 1
		}
		delete(oldMetrics, "max_file_lines")
		delete(oldDir, "max_file_lines")

		acceptSet := make(map[string]bool)
		for _, k := range strings.Split(flags.AcceptKeys, ",") {
			k = strings.TrimSpace(k)
			if k != "" {
				acceptSet[k] = true
			}
		}

		kept := make(map[string]bool)
		for k, ov := range oldMetrics {
			_, inCurrent := currentMetrics[k]
			if !inCurrent && oldDir[k] == "hi" {
				kept[k] = true
				currentMetrics[k] = ov
				currentDir[k] = "hi"
			}
		}

		for k, cur := range currentMetrics {
			if acceptSet[k] {
				continue
			}
			dir := currentDir[k]
			if dir == "" {
				dir = oldDir[k]
			}
			if dir == "" {
				dir = "lo"
			}
			old, hadOld := oldMetrics[k]
			if !hadOld {
				old = cur
			}
			if dir == "hi" {
				currentMetrics[k] = NumberMax(old, cur)
			} else {
				currentMetrics[k] = NumberMin(old, cur)
			}
		}

		newBaseline = buildBaselineMap(currentMetrics, currentDir)

		existing, _ := os.ReadFile(baselinePath)
		var oldDoc map[string]interface{}
		if err := json.Unmarshal(existing, &oldDoc); err == nil {
			oldAccepted, _ := oldDoc["accepted"].(map[string]interface{})
			acceptedEntries := make(map[string]interface{})
			if oldAccepted != nil {
				for k, v := range oldAccepted {
					if k != "max_file_lines" {
						acceptedEntries[k] = v
					}
				}
			}
			today := time.Now().UTC().Format("2006-01-02")
			for _, k := range acceptedNow {
				if k == "max_file_lines" {
					continue
				}
				from := "0"
				sticky := false
				if oldAccepted != nil {
					if prev, ok := oldAccepted[k].(map[string]interface{}); ok {
						if f, ok := prev["from"]; ok {
							if b, err := json.Marshal(f); err == nil {
								from = string(b)
								sticky = true
							}
						}
					}
				}
				if !sticky && oldMetrics[k].Sign != 0 {
					b, _ := oldMetrics[k].MarshalJSON()
					from = string(b)
				}
				toBytes, _ := currentMetrics[k].MarshalJSON()
				acceptedEntries[k] = map[string]interface{}{
					"from": json.RawMessage(from), "to": json.RawMessage(toBytes),
					"at": today, "reason": flags.AcceptReason,
				}
			}
			for k, v := range acceptedEntries {
				if entry, ok := v.(map[string]interface{}); ok {
					dir := currentDir[k]
					if dir == "" {
						dir = "lo"
					}
					toNum, hasCurrent := currentMetrics[k]
					fromStr := "0"
					if raw := entry["from"]; raw != nil {
						if b, err := json.Marshal(raw); err == nil {
							fromStr = string(b)
						}
					}
					fromNum, _ := ParseNumber(json.RawMessage(fromStr))

					isRegression := false
					if dir == "hi" {
						if toNum.Float64() < fromNum.Float64()-1e-9 {
							isRegression = true
						}
					} else {
						if toNum.Float64() > fromNum.Float64()+1e-9 {
							isRegression = true
						}
					}
					if !isRegression {
						delete(acceptedEntries, k)
					} else if hasCurrent {
						toBytes, _ := toNum.MarshalJSON()
						entry["to"] = json.RawMessage(toBytes)
					}
				}
			}
			if len(acceptedEntries) > 0 {
				newBaseline["accepted"] = acceptedEntries
			}
		}
	} else {
		newBaseline = buildBaselineMap(currentMetrics, currentDir)
	}

	newJSON := marshalBaseline(newBaseline)
	existing, _ := os.ReadFile(baselinePath)

	if fileExists(baselinePath) {
		oldKeys := baselineKeys(existing)
		newKeys := baselineKeys([]byte(newJSON))
		var pruned []string
		for _, k := range oldKeys {
			found := false
			for _, nk := range newKeys {
				if k == nk {
					found = true
					break
				}
			}
			if !found {
				pruned = append(pruned, k)
			}
		}
		if len(pruned) > 0 {
			warn("baseline: pruning resolved ceiling(s): %s — a key vanishes when its debt is fixed OR its check stopped running; confirm the latter is intended", strings.Join(pruned, ", "))
		}
	}

	if flags.AcceptRegression && fileExists(baselinePath) {
		warn("accepting regressions — baseline diff:")
	}

	tmp, err := os.CreateTemp(filepath.Dir(baselinePath), filepath.Base(baselinePath)+".*")
	if err != nil {
		warn("baseline: cannot stage next to %s — not writing", baselinePath)
		return 1
	}
	tmpName := tmp.Name()
	if _, err := tmp.WriteString(newJSON); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		warn("baseline: staging write failed — not writing")
		return 1
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		warn("baseline: staging close failed — not writing")
		return 1
	}

	if fileExists(baselinePath) {
		info, _ := os.Stat(baselinePath)
		os.Chmod(tmpName, info.Mode())
	} else {
		os.Chmod(tmpName, 0600)
	}

	if fileExists(baselinePath) {
		old, _ := os.ReadFile(baselinePath)
		newD, _ := os.ReadFile(tmpName)
		if string(old) == string(newD) {
			os.Remove(tmpName)
			fmt.Println("[+] baseline already records the current metric floor")
			return 0
		}
	}

	if err := os.Rename(tmpName, baselinePath); err != nil {
		os.Remove(tmpName)
		warn("baseline: atomic replacement failed — original preserved")
		return 1
	}
	fmt.Println("[ok] baseline tightened at " + baselinePath)
	return 0
}

func buildBaselineMap(metrics map[string]Number, dirs map[string]string) map[string]interface{} {
	sortedMetrics := make(map[string]interface{})
	keys := make([]string, 0, len(metrics))
	for k := range metrics {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		sortedMetrics[k] = metrics[k]
	}
	return map[string]interface{}{
		"metrics":   sortedMetrics,
		"direction": dirs,
	}
}

func marshalBaseline(m map[string]interface{}) string {
	var b strings.Builder
	b.WriteString("{\n")
	keys := []string{"metrics", "direction", "accepted"}
	written := 0
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if written > 0 {
				b.WriteString(",\n")
			}
			b.WriteString(fmt.Sprintf("  %q: ", k))
			writeValue(&b, v)
			written++
		}
	}
	b.WriteString("\n}\n")
	return b.String()
}

func writeValue(b *strings.Builder, v interface{}) {
	switch val := v.(type) {
	case map[string]interface{}:
		b.WriteString("{\n")
		keys := make([]string, 0, len(val))
		for k := range val {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for i, k := range keys {
			b.WriteString(fmt.Sprintf("  %q: ", k))
			writeValue(b, val[k])
			if i < len(keys)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString("}")
	case map[string]Number:
		b.WriteString("{\n")
		keys := make([]string, 0, len(val))
		for k := range val {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for i, k := range keys {
			n := val[k]
			buf, _ := n.MarshalJSON()
			b.WriteString(fmt.Sprintf("  %q: %s", k, string(buf)))
			if i < len(keys)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString("}")
	case map[string]string:
		b.WriteString("{\n")
		keys := make([]string, 0, len(val))
		for k := range val {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for i, k := range keys {
			encoded, _ := json.Marshal(val[k])
			b.WriteString(fmt.Sprintf("  %q: %s", k, string(encoded)))
			if i < len(keys)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString("}")
	case Number:
		buf, _ := val.MarshalJSON()
		b.WriteString(string(buf))
	case string:
		b.WriteString(fmt.Sprintf("%q", val))
	case float64:
		b.WriteString(fmt.Sprintf("%g", val))
	default:
		buf, _ := json.Marshal(val)
		b.WriteString(string(buf))
	}
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func baselineKeys(data []byte) []string {
	var doc map[string]interface{}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil
	}
	metrics, _ := doc["metrics"].(map[string]interface{})
	if metrics == nil {
		return nil
	}
	keys := make([]string, 0, len(metrics))
	for k := range metrics {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
