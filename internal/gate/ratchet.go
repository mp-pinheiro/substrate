package gate

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
)

type RatchetResult struct {
	AcceptedNow []string
	Worse       []string
	Better      int
	BudgetWarn  []string
}

func RunRatchet(metricsOut, baselinePath, configPath string, flags PreflightFlags) (*RatchetResult, int) {
	result := &RatchetResult{}

	currentMetrics := make(map[string]Number)
	currentDir := make(map[string]string)

	data, err := os.ReadFile(metricsOut)
	if err != nil {
		warn("ratchet: cannot read metrics: %v", err)
		return result, 1
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
		if m.Dir != "" {
			currentDir[m.Name] = m.Dir
		}
		n, err := ParseNumber(m.Value)
		if err != nil {
			continue
		}
		currentMetrics[m.Name] = n
	}

	neverAccept := getNeverAccept(configPath)
	budgets := getBudgets(configPath)

	if _, err := os.Stat(baselinePath); os.IsNotExist(err) {
		total := len(currentMetrics)
		warn("ratchet: no baseline yet (%d metric(s) pending) — run --update-baseline on a green run to grandfather current debt", total)
		return result, 0
	}

	baseMetrics, baseDir, err := loadBaseline(baselinePath)
	if err != nil {
		warn("ratchet: cannot read baseline metrics")
		return result, 1
	}

	var worse []string
	for name, cur := range currentMetrics {
		dir := currentDir[name]
		if dir == "" {
			dir = baseDir[name]
		}
		if dir == "" {
			dir = "lo"
		}
		base, ok := baseMetrics[name]
		if !ok {
			base = Number{Sign: 0, Digits: "0", Exp: 0}
		}
		curF := cur.Float64()
		baseF := base.Float64()
		budget := budgets[name]
		regressed := false
		capMsg := ""

		if budget > 0 && dir != "hi" {
			regressed = curF > budget
			if curF > budget {
				capMsg = fmt.Sprintf(", hard cap %.0f — over cap", budget)
			} else {
				capMsg = fmt.Sprintf(", hard cap %.0f — %.0f under cap", budget, budget-curF)
			}
		} else {
			if dir == "hi" {
				regressed = curF < baseF-1e-9
			} else {
				regressed = curF > baseF+1e-9
			}
		}
		if regressed {
			bestVal := baseF
			if budget > 0 && dir != "hi" {
				bestVal = budget
			}
			worse = append(worse, fmt.Sprintf("%s: %s (best %.6g%s)", name, string(cur.Raw), bestVal, capMsg))
		}
	}

	var better int
	for name := range baseMetrics {
		dir := currentDir[name]
		if dir == "" {
			dir = baseDir[name]
		}
		if dir == "" {
			dir = "lo"
		}
		cur, ok := currentMetrics[name]
		if !ok {
			cur = Number{Sign: 0, Digits: "0", Exp: 0}
		}
		base := baseMetrics[name]
		curF := cur.Float64()
		baseF := base.Float64()
		if dir == "hi" {
			if curF > baseF+1e-9 {
				better++
			}
		} else {
			if curF < baseF-1e-9 {
				better++
			}
		}
	}

	var budgetWarn []string
	for name, cur := range currentMetrics {
		budget, ok := budgets[name]
		if !ok || budget <= 0 {
			continue
		}
		curF := cur.Float64()
		if !math.IsInf(curF, 0) && curF/budget >= 0.8 {
			pct := int(curF * 100 / budget)
			budgetWarn = append(budgetWarn, fmt.Sprintf("%s: %s/%.0f (%d%% used)", name, string(cur.Raw), budget, pct))
		}
	}
	sort.Strings(budgetWarn)

	result.Better = better
	result.BudgetWarn = budgetWarn

	for _, bw := range budgetWarn {
		fmt.Println(bw)
	}
	if len(budgetWarn) > 0 {
		warn("ratchet: budget metric(s) at 80%%+ of cap — consider refactoring")
	}

	if len(worse) > 0 {
		if flags.AcceptRegression && flags.AcceptKeys != "" {
			acceptSet := make(map[string]bool)
			for _, k := range strings.Split(flags.AcceptKeys, ",") {
				acceptSet[strings.TrimSpace(k)] = true
			}
			var accepted, rejected, neverAccepted []string
			for _, line := range worse {
				key := strings.SplitN(line, ":", 2)[0]
				if !acceptSet[key] {
					rejected = append(rejected, line)
					continue
				}
				if neverAccept[key] {
					neverAccepted = append(neverAccepted, line)
				} else {
					accepted = append(accepted, line)
					result.AcceptedNow = append(result.AcceptedNow, key)
				}
			}
			if len(rejected) > 0 {
				for _, r := range rejected {
					fmt.Println(r)
				}
				warn("FAIL ratchet: non-accepted metrics regressed")
				result.Worse = worse
				return result, 1
			}
			if len(neverAccepted) > 0 {
				for _, n := range neverAccepted {
					fmt.Println(n)
					key := strings.SplitN(n, ":", 2)[0]
					warn("FAIL ratchet: %s is never-acceptable (ratchet.never_accept in substrate.json) — fix the regression or change that policy in a separate reviewed commit", strings.TrimSpace(key))
				}
				result.Worse = worse
				return result, 1
			}
			if len(accepted) > 0 {
				for _, a := range accepted {
					fmt.Println(a)
				}
				warn("ratchet: accepted regression(s) per --accept-regression=%s", flags.AcceptKeys)
			}
		} else if flags.AcceptRegression {
			var neverAccepted []string
			for _, line := range worse {
				key := strings.SplitN(line, ":", 2)[0]
				if neverAccept[key] {
					neverAccepted = append(neverAccepted, line)
				} else {
					result.AcceptedNow = append(result.AcceptedNow, key)
				}
			}
			if len(neverAccepted) > 0 {
				for _, n := range neverAccepted {
					fmt.Println(n)
					key := strings.SplitN(n, ":", 2)[0]
					warn("FAIL ratchet: %s is never-acceptable (ratchet.never_accept in substrate.json) — fix the regression or change that policy in a separate reviewed commit", strings.TrimSpace(key))
				}
				result.Worse = worse
				return result, 1
			}
			for _, w := range worse {
				fmt.Println(w)
			}
			warn("ratchet: metrics regressed — explicit regression acceptance requested")
		} else {
			for _, w := range worse {
				fmt.Println(w)
			}
			warn("FAIL ratchet: metrics regressed beyond their grandfathered baseline")
			warn("ratchet: raising a ceiling is permanent and lands in the committed diff — cost the refactor before accepting (guides/working-with-the-gate.md, \"Accept or refactor\")")
			result.Worse = worse
			return result, 1
		}
	} else if better > 0 {
		info("ratchet: %d metric(s) improved on baseline — checkpoint locks them in automatically", better)
	} else {
		successMsg("ratchet: all metrics at or better than baseline")
	}

	return result, 0
}

func getNeverAccept(configPath string) map[string]bool {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil
	}
	var cfg struct {
		Ratchet struct {
			NeverAccept []string `json:"never_accept"`
		} `json:"ratchet"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil
	}
	m := make(map[string]bool)
	for _, k := range cfg.Ratchet.NeverAccept {
		m[k] = true
	}
	return m
}

func getBudgets(configPath string) map[string]float64 {
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil
	}
	var cfg struct {
		Budgets map[string]float64 `json:"budgets"`
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil
	}
	return cfg.Budgets
}

func loadBaseline(path string) (map[string]Number, map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, fmt.Errorf("read baseline: %w", err)
	}
	var raw struct {
		Metrics   map[string]json.RawMessage `json:"metrics"`
		Direction map[string]string          `json:"direction"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, nil, fmt.Errorf("parse baseline: %w", err)
	}
	metrics := make(map[string]Number)
	for k, v := range raw.Metrics {
		n, err := ParseNumber(v)
		if err != nil {
			continue
		}
		metrics[k] = n
	}
	if raw.Direction == nil {
		raw.Direction = make(map[string]string)
	}
	return metrics, raw.Direction, nil
}
