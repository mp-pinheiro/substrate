package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Baseline struct {
	Metrics   map[string]float64
	Direction map[string]string
}

func LoadBaseline(path string) (*Baseline, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return &Baseline{Metrics: map[string]float64{}, Direction: map[string]string{}}, nil
		}
		return nil, fmt.Errorf("config: read baseline %s: %w", path, err)
	}

	var raw struct {
		Metrics   map[string]json.RawMessage `json:"metrics"`
		Direction map[string]string          `json:"direction"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("config: parse baseline %s: %w", path, err)
	}
	metrics := make(map[string]float64, len(raw.Metrics))
	for key, val := range raw.Metrics {
		if n, ok := parseMetricValue(val); ok {
			metrics[key] = n
		}
	}
	if raw.Direction == nil {
		raw.Direction = map[string]string{}
	}
	return &Baseline{Metrics: metrics, Direction: raw.Direction}, nil
}

// parseMetricValue mirrors `jq -r '.metrics[$k] // 0'` feeding bash's `-gt` integer test.
func parseMetricValue(raw json.RawMessage) (float64, bool) {
	var n float64
	if err := json.Unmarshal(raw, &n); err == nil {
		return n, true
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		if v, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err == nil {
			return v, true
		}
	}
	return 0, false
}

func (b *Baseline) Metric(key string) (float64, bool) {
	if b == nil {
		return 0, false
	}
	v, ok := b.Metrics[key]
	return v, ok
}

// bash's `[ -gt ]` on a fractional metric is a runtime type error, not a
// truncation; this contract truncates toward zero instead of reproducing that crash.
func (b *Baseline) Allowance(key string) int {
	if b == nil {
		return 0
	}
	v, ok := b.Metrics[key]
	if !ok {
		return 0
	}
	return int(v)
}
