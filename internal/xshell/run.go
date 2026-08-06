package xshell

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
)

type Result struct {
	Stdout []byte
	Stderr []byte
	Code   int
}

type runOpts struct {
	dir     string
	stdin   []byte
	localeC bool
}

func run(ctx context.Context, name string, args []string, opts runOpts) (Result, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = opts.dir
	if opts.stdin != nil {
		cmd.Stdin = bytes.NewReader(opts.stdin)
	}
	if opts.localeC {
		cmd.Env = append(os.Environ(), "LC_ALL=C")
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	result := Result{Code: -1}
	err := cmd.Run()
	result.Stdout = stdout.Bytes()
	result.Stderr = stderr.Bytes()

	if err == nil {
		result.Code = 0
		return result, nil
	}
	if ctxErr := ctx.Err(); ctxErr != nil {
		return result, fmt.Errorf("xshell: run %s: %w", name, ctxErr)
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		result.Code = exitErr.ExitCode()
		return result, nil
	}
	return result, fmt.Errorf("xshell: run %s: %w", name, err)
}

func Run(ctx context.Context, name string, args ...string) (Result, error) {
	return run(ctx, name, args, runOpts{})
}

func RunIn(ctx context.Context, dir string, name string, args ...string) (Result, error) {
	return run(ctx, name, args, runOpts{dir: dir})
}

func RunStdin(ctx context.Context, dir string, stdin []byte, name string, args ...string) (Result, error) {
	return run(ctx, name, args, runOpts{dir: dir, stdin: stdin})
}

func RunC(ctx context.Context, name string, args ...string) (Result, error) {
	return run(ctx, name, args, runOpts{localeC: true})
}

func RunInC(ctx context.Context, dir string, name string, args ...string) (Result, error) {
	return run(ctx, name, args, runOpts{dir: dir, localeC: true})
}

func RunStdinC(ctx context.Context, dir string, stdin []byte, name string, args ...string) (Result, error) {
	return run(ctx, name, args, runOpts{dir: dir, stdin: stdin, localeC: true})
}

func Have(bin string) bool {
	_, err := exec.LookPath(bin)
	return err == nil
}
