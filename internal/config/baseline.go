package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
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
		Metrics   map[string]float64 `json:"metrics"`
		Direction map[string]string  `json:"direction"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("config: parse baseline %s: %w", path, err)
	}
	if raw.Metrics == nil {
		raw.Metrics = map[string]float64{}
	}
	if raw.Direction == nil {
		raw.Direction = map[string]string{}
	}
	return &Baseline{Metrics: raw.Metrics, Direction: raw.Direction}, nil
}

func (b *Baseline) Metric(key string) (float64, bool) {
	v, ok := b.Metrics[key]
	return v, ok
}

// WHY: bash's `[ -gt ]` on a fractional metric is a runtime type error, not a
// truncation; this contract truncates toward zero instead of reproducing that crash.
func (b *Baseline) Allowance(key string) int {
	v, ok := b.Metrics[key]
	if !ok {
		return 0
	}
	return int(v)
}
