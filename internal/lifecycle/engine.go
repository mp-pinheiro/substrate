package lifecycle

import (
	"context"
	"io"
	"os"
	"path/filepath"

	"github.com/mp-pinheiro/substrate/internal/config"
	"github.com/mp-pinheiro/substrate/internal/vcs"
)

const (
	msgInvalidSession       = "substrate lifecycle: invalid session id\n"
	msgMalformedPayload     = "substrate lifecycle: malformed hook payload\n"
	msgCannotCreateStateDir = "substrate lifecycle: cannot create state directory\n"
	msgStateWriteFailed     = "substrate lifecycle: state write failed\n"
	msgUsage                = "usage: agent-lifecycle.sh start|observe|verify <session>|status <session>|complete <session> <commit>|stop|end\n"
)

type Result struct {
	Stdout []byte
	Stderr []byte
	Code   int
}

type Engine struct {
	paths    config.Paths
	repo     *vcs.Repo
	stateDir string
}

func New(paths config.Paths, repo *vcs.Repo) *Engine {
	return &Engine{paths: paths, repo: repo}
}

func (e *Engine) SetStateDir(dir string) {
	e.stateDir = dir
}

func (e *Engine) statePath(session string) string {
	return filepath.Join(e.stateDir, session+".json")
}

// Run mirrors core/hooks/agent-lifecycle.sh's shared preamble and dispatch.
func (e *Engine) Run(ctx context.Context, args []string, stdin io.Reader) Result {
	action := ""
	if len(args) > 0 {
		action = args[0]
	}

	metadata, err := e.repo.MetadataDir(ctx)
	if err != nil {
		return Result{Code: 0}
	}
	e.stateDir = filepath.Join(metadata, "substrate", "agent-sessions")
	if err := os.MkdirAll(e.stateDir, 0o755); err != nil {
		return Result{Stderr: []byte(msgCannotCreateStateDir), Code: 2}
	}

	var payload []byte
	var session string
	switch action {
	case "start", "observe", "stop", "end":
		data, _ := io.ReadAll(stdin)
		payload = data
		var malformed bool
		session, malformed = sessionFromPayload(payload)
		if malformed {
			return Result{Stderr: []byte(msgMalformedPayload), Code: 2}
		}
	default:
		if len(args) > 1 {
			session = args[1]
		}
	}

	if !validSessionID(session) {
		return Result{Stderr: []byte(msgInvalidSession), Code: 2}
	}

	switch action {
	case "start":
		return e.Start(ctx, payload)
	case "observe":
		return e.Observe(ctx, payload)
	case "verify":
		return e.Verify(ctx, session)
	case "status":
		return e.Status(ctx, session)
	case "complete":
		commit := ""
		if len(args) > 2 {
			commit = args[2]
		}
		return e.Complete(ctx, session, commit)
	case "stop":
		return e.Stop(ctx, payload)
	case "end":
		return e.End(session)
	default:
		return Result{Stderr: []byte(msgUsage), Code: 2}
	}
}

func validSessionID(s string) bool {
	if s == "" {
		return false
	}
	for i := range s {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '.' || c == '_' || c == '-':
		default:
			return false
		}
	}
	return true
}
