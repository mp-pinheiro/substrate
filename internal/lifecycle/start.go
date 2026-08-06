package lifecycle

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

func (e *Engine) Start(ctx context.Context, payload []byte) Result {
	session, _ := sessionFromPayload(payload)
	statePath := e.statePath(session)

	warning := e.reportRefreshWarning(ctx)
	current := e.snapshot(ctx)

	state := newLedger(session, e.paths.RepoRoot, current, nullable(current.Error))

	if err := e.writeLedger(statePath, state); err != nil {
		return Result{Stderr: []byte(msgStateWriteFailed), Code: 2}
	}

	msg := fmt.Sprintf(
		"Substrate lifecycle active. After direct verification, checkpoint with: "+
			"substrate checkpoint --session %s --message 'type(scope): subject'. Never commit or push directly.",
		session)
	if warning != "" {
		msg += " " + warning
	}

	doc := canonjson.NewObject().Set("hookSpecificOutput", canonjson.NewObject().
		Set("hookEventName", "SessionStart").
		Set("additionalContext", msg))
	out, err := marshalLine(doc)
	if err != nil {
		return Result{Code: 2}
	}
	return Result{Stdout: out, Code: 0}
}

func (e *Engine) reportRefreshWarning(ctx context.Context) string {
	reportPath := filepath.Join(e.paths.SubstrateDir, "report.sh")
	info, err := os.Stat(reportPath)
	if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
		return ""
	}
	res, err := xshell.RunIn(ctx, e.paths.RepoRoot, reportPath, "--refresh")
	if err != nil {
		return ""
	}
	return trimTrailingNewlines(string(res.Stderr))
}
