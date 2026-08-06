package comments

import "fmt"

type Finding struct {
	Name string
	Line int
	Rule string
	Text string
}

func (f Finding) String() string {
	return fmt.Sprintf("%s:%d: %s: %s", f.Name, f.Line, f.Rule, f.Text)
}

// InfrastructureError mirrors the detector's fail-closed exit codes (>=2):
// callers must not treat a scan as clean when this is returned.
type InfrastructureError struct {
	Code int
	Err  error
}

func (e *InfrastructureError) Error() string { return e.Err.Error() }
func (e *InfrastructureError) Unwrap() error { return e.Err }

func infraErrf(format string, a ...any) *InfrastructureError {
	return &InfrastructureError{Code: 3, Err: fmt.Errorf(format, a...)}
}
