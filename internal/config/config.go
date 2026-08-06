package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

type Contract struct {
	Name  string
	Regen string
	Paths []string
}

type Scope struct {
	Profiles []string
}

type Config struct {
	Profiles       []string
	Unscanned      []string
	ProtectedPaths []string
	Contracts      []Contract
	Scopes         map[string]Scope
	CommentTags    []string
	Present        bool

	contractsValid bool
}

var defaultCommentTags = []string{"SAFETY:", "WHY:", "PERF:", "HACK:"}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return &Config{Present: false, contractsValid: true}, nil
		}
		return nil, fmt.Errorf("config: read %s: %w", path, err)
	}

	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", path, err)
	}

	cfg := &Config{Present: true}
	decodeStringSlice(top["profiles"], &cfg.Profiles)
	decodeStringSlice(top["unscanned"], &cfg.Unscanned)
	decodeStringSlice(top["protected_paths"], &cfg.ProtectedPaths)
	cfg.Scopes = decodeScopes(top["scopes"])
	cfg.Contracts, cfg.contractsValid = decodeContracts(top["contracts"])
	cfg.CommentTags = decodeCommentTags(top["comment"])

	return cfg, nil
}

func (c *Config) ContractsValid() bool {
	return c.contractsValid
}

func (c *Config) ScopeAllows(path, profile string) bool {
	if len(c.Scopes) == 0 {
		return true
	}
	restricted := false
	for scopePath, scope := range c.Scopes {
		if scopePath == "" || !strings.HasPrefix(path, scopePath) {
			continue
		}
		restricted = true
		for _, p := range scope.Profiles {
			if p == profile {
				return true
			}
		}
	}
	return !restricted
}

func decodeStringSlice(raw json.RawMessage, dest *[]string) {
	if len(raw) == 0 {
		return
	}
	var v []string
	if err := json.Unmarshal(raw, &v); err != nil {
		return
	}
	*dest = v
}

type rawScope struct {
	Profiles []string `json:"profiles"`
}

func decodeScopes(raw json.RawMessage) map[string]Scope {
	if len(raw) == 0 {
		return nil
	}
	var v map[string]rawScope
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil
	}
	scopes := make(map[string]Scope, len(v))
	for k, rs := range v {
		scopes[k] = Scope(rs)
	}
	return scopes
}

type rawContract struct {
	Name  json.RawMessage `json:"name"`
	Regen json.RawMessage `json:"regen"`
	Paths json.RawMessage `json:"paths"`
}

func decodeContracts(raw json.RawMessage) ([]Contract, bool) {
	if len(raw) == 0 {
		return nil, true
	}
	var entries []rawContract
	if err := json.Unmarshal(raw, &entries); err != nil {
		return nil, false
	}
	contracts := make([]Contract, 0, len(entries))
	valid := true
	for _, e := range entries {
		name, nameOK := decodeJSONString(e.Name)
		regen, regenOK := decodeJSONString(e.Regen)
		paths, pathsOK := decodeJSONStringArray(e.Paths)
		if !nameOK || !regenOK || !pathsOK {
			valid = false
		}
		contracts = append(contracts, Contract{Name: name, Regen: regen, Paths: paths})
	}
	return contracts, valid
}

func decodeJSONString(raw json.RawMessage) (string, bool) {
	if len(raw) == 0 {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", false
	}
	return s, true
}

func decodeJSONStringArray(raw json.RawMessage) ([]string, bool) {
	if len(raw) == 0 {
		return nil, false
	}
	var elems []json.RawMessage
	if err := json.Unmarshal(raw, &elems); err != nil {
		return nil, false
	}
	paths := make([]string, 0, len(elems))
	for _, el := range elems {
		var s string
		if err := json.Unmarshal(el, &s); err == nil {
			paths = append(paths, s)
		}
	}
	return paths, true
}

func decodeCommentTags(raw json.RawMessage) []string {
	if len(raw) == 0 {
		return append([]string(nil), defaultCommentTags...)
	}
	var comment struct {
		AllowTags *[]string `json:"allow_tags"`
	}
	if err := json.Unmarshal(raw, &comment); err != nil || comment.AllowTags == nil {
		return append([]string(nil), defaultCommentTags...)
	}
	return *comment.AllowTags
}
