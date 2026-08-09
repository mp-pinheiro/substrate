// Package maintenance ports core/maintenance.sh, the kit self-update
// and repo-scaffold evolution state machine (P4b).
package maintenance

// Operation names matching bash MAINTENANCE_OPERATION values.
const (
	OpInit      = "init"
	OpBootstrap = "bootstrap"
	OpUpdate    = "update"
)

// Repository status values matching bash receipt states.
const (
	StatusPrepared   = "prepared"
	StatusApplying   = "applying"
	StatusApplied    = "applied"
	StatusIncomplete = "incomplete"
	StatusCommitted  = "committed"
	StatusNoop       = "noop"
)

// Phase status values.
const (
	PhasePending = "pending"
	PhasePassed  = "passed"
	PhaseFailed  = "failed"
	PhaseSkipped = "skipped"
)

// Unit describes one managed path change: what it was (preimage), what it
// should become (desired), and whether it has been applied.
type Unit struct {
	Path     string `json:"path"`
	Preimage string `json:"preimage"`
	Desired  string `json:"desired"`
	Applied  bool   `json:"applied,omitempty"`
}

// RepositorySection holds the repository-scoped receipt state.
type RepositorySection struct {
	Status                  string   `json:"status"`
	VCS                     string   `json:"vcs"`
	FromRevision            *string  `json:"fromRevision"`
	ToRevision              *string  `json:"toRevision"`
	Commit                  *string  `json:"commit"`
	Message                 string   `json:"message"`
	CheckpointRequested     bool     `json:"checkpointRequested"`
	Manifest                []string `json:"manifest"`
	ChangedPaths            []string `json:"changedPaths"`
	Units                   []Unit   `json:"units"`
	PreservedDirtyFingerprint string  `json:"preservedDirtyFingerprint"`
	GateHash                string   `json:"gateHash"`
	CandidatePath           *string  `json:"candidatePath"`
}

// PhaseSection holds one external phase's status.
type PhaseSection struct {
	Status string `json:"status"`
}

// Receipt is the maintenance transaction receipt (schemaVersion 1).
type Receipt struct {
	SchemaVersion int                `json:"schemaVersion"`
	ID            string             `json:"id"`
	Operation     string             `json:"operation"`
	EngineVersion string             `json:"engineVersion"`
	Repository    RepositorySection  `json:"repository"`
	RepoRuntime   PhaseSection       `json:"repoRuntime"`
	UserHarness   PhaseSection       `json:"userHarness"`
	NoPush        bool               `json:"noPush"`
	At            string             `json:"at"`
}

// Context holds the parsed maintenance arguments and runtime state.
type Context struct {
	Operation        string
	Profiles         []string
	ProfileCSV       string
	Force            bool
	FromWorktree     bool
	Checkpoint       bool
	AcceptBaseline   bool
	AcceptRegression string
	AcceptReason     string
	JSON             bool
	RepoOnly         bool
	RequestedVCS     string
	VCS              string
	Message          string

	// Resolved at runtime
	RepoRoot    string
	MetadataDir string
	StoreDir    string
	LockPath    string
	StablePath  string
	TxID        string
	TxDir       string
	CandidateDir string
}
