package logx

import (
	"fmt"
	"io"
	"os"
)

type Writer struct {
	w   io.Writer
	err error
}

func NewWriter(w io.Writer) *Writer {
	return &Writer{w: w}
}

var (
	stdout *Writer
	stderr *Writer
)

func Out() *Writer {
	if stdout == nil {
		stdout = NewWriter(os.Stdout)
	}
	return stdout
}

func Err() *Writer {
	if stderr == nil {
		stderr = NewWriter(os.Stderr)
	}
	return stderr
}

func (w *Writer) Write(p []byte) (int, error) {
	n, err := w.w.Write(p)
	if err != nil {
		err = fmt.Errorf("logx: write: %w", err)
		if w.err == nil {
			w.err = err
		}
	}
	return n, err
}

func (w *Writer) Print(s string) {
	_, _ = w.Write([]byte(s))
}

func (w *Writer) Printf(format string, a ...any) {
	w.Print(fmt.Sprintf(format, a...))
}

func (w *Writer) Line(format string, a ...any) {
	w.Printf(format+"\n", a...)
}

func (w *Writer) Err() error {
	return w.err
}

func Info(msg string) {
	Out().Line("\033[0;34m[+]\033[0m %s", msg)
}

func Success(msg string) {
	Out().Line("\033[0;32m[ok]\033[0m %s", msg)
}

func Warn(msg string) {
	Out().Line("\033[0;33m[!]\033[0m %s", msg)
}
