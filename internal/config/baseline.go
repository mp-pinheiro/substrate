package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

type Baseline struct {
	Metrics   map[string]json.RawMessage
	Direction map[string]string
}

func LoadBaseline(path string) (*Baseline, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return &Baseline{Metrics: map[string]json.RawMessage{}, Direction: map[string]string{}}, nil
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
	if raw.Metrics == nil {
		raw.Metrics = map[string]json.RawMessage{}
	}
	if raw.Direction == nil {
		raw.Direction = map[string]string{}
	}
	return &Baseline{Metrics: raw.Metrics, Direction: raw.Direction}, nil
}

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
	raw, ok := b.Metrics[key]
	if !ok {
		return 0, false
	}
	return parseMetricValue(raw)
}

var wholeNumberPattern = regexp.MustCompile(`^[0-9]+$`)

type MetricNotWholeNumberError struct {
	Key string
}

func (e *MetricNotWholeNumberError) Error() string {
	return fmt.Sprintf("config: baseline metric %s is not a whole number", e.Key)
}

// jqRawText mirrors `jq -r '... // 0'`: null/false are the falsy default (0),
// strings are unquoted, everything else renders as compact JSON text.
func jqRawText(raw json.RawMessage) (text string, truthy bool) {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "null" || trimmed == "false" {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s, true
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, raw); err == nil {
		return compact.String(), true
	}
	return trimmed, true
}

func (b *Baseline) Allowance(key string) (int, error) {
	if b == nil {
		return 0, nil
	}
	raw, ok := b.Metrics[key]
	if !ok {
		return 0, nil
	}
	text, truthy := jqRawText(raw)
	if !truthy {
		return 0, nil
	}
	if !wholeNumberPattern.MatchString(text) {
		return 0, &MetricNotWholeNumberError{Key: key}
	}
	n, err := strconv.Atoi(text)
	if err != nil {
		return 0, &MetricNotWholeNumberError{Key: key}
	}
	return n, nil
}
