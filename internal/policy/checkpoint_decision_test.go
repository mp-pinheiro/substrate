package policy

import (
	"testing"

	"github.com/mp-pinheiro/substrate/internal/config"
)

func TestCheckpointDecision(t *testing.T) {
	cfg := &config.Config{Present: true, AskPaths: []string{"wsl-mounts/*"}}
	cases := []struct {
		path string
		cfg  *config.Config
		want Level
	}{
		{"substrate-baseline.json", cfg, LevelBlock},
		{".substrate/gate.sh", cfg, LevelBlock},
		{"CLAUDE.md", cfg, LevelAsk},
		{"claude/CLAUDE.md", cfg, LevelAsk},
		{"AGENTS.md", nil, LevelAsk},
		{"wsl-mounts/map_shares.bat", cfg, LevelAsk},
		{"wsl-mounts/map_shares.bat", nil, LevelAllow},
		{"components/omp.sh", cfg, LevelAllow},
	}
	for _, c := range cases {
		if got := CheckpointDecision(c.path, c.cfg); got.Level != c.want {
			t.Errorf("%s: level %d, want %d (%q)", c.path, got.Level, c.want, got.Message)
		}
	}
}
