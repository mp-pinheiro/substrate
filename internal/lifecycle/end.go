package lifecycle

import "os"

func (e *Engine) End(session string) Result {
	_ = os.Remove(e.statePath(session))
	return Result{Code: 0}
}
