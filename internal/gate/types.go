package gate

import "context"

type MetricRecord struct {
	Name     string
	RawValue []byte
	Dir      string
}

type CheckResult struct {
	Name    string
	RC      int
	MS      int
	Output  string
	Metrics []MetricRecord
}

type CheckEnv struct {
	CheckName  string
	Metrics    string
	Inventory  string
	Claims     string
	RepoRoot   string
	SubDir     string
	Config     string
	Langmap    string
	Baseline   string
	ClaimsEnvs map[string]string
}

type RunFn func(ctx context.Context, inv []string, claims []byte, env map[string]string) (rc int, metrics []MetricRecord, output string, err error)
