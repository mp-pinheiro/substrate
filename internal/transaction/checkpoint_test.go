package transaction

import (
	"testing"

	"github.com/mp-pinheiro/substrate/internal/policy"
)

func TestClassifyCheckpointFailsClosed(t *testing.T) {
	cases := []struct {
		level policy.Level
		want  checkpointClass
	}{
		{policy.LevelAllow, checkpointCommit},
		{policy.LevelWarn, checkpointCommit},
		{policy.LevelAsk, checkpointHandoff},
		{policy.LevelBlock, checkpointRefuse},
		{0, checkpointRefuse},
		{policy.LevelBlock + 1, checkpointRefuse},
	}
	for _, c := range cases {
		if got := classifyCheckpoint(policy.Decision{Level: c.level}); got != c.want {
			t.Errorf("level %d: class %d, want %d", c.level, got, c.want)
		}
	}
}
