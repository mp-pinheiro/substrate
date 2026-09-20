package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/enginecli"
	"github.com/mp-pinheiro/substrate/internal/kit"
)

var (
	version     = "0.0.0-dev"
	channel     = "dev"
	kitRevision = ""
)

func resolveIdentity() (string, string, string) {
	v, ch := version, channel
	if v == "0.0.0-dev" {
		if bi, ok := debug.ReadBuildInfo(); ok {
			mv := bi.Main.Version
			if mv != "" && mv != "(devel)" {
				v, ch = strings.TrimPrefix(mv, "v"), "module"
			}
		}
	}
	if ch == "dev" {
		return v, ch, v
	}
	return v + "+" + ch, ch, v
}

func main() {
	reported, ch, bare := resolveIdentity()
	if filepath.Base(os.Args[0]) == "substrate-engine" {
		exportKitRoot()
		os.Exit(enginecli.Run(os.Args[1:], reported))
	}
	if len(os.Args) > 1 && os.Args[1] == "__engine" {
		exportKitRoot()
		os.Exit(enginecli.Run(os.Args[2:], reported))
	}
	os.Exit(runCLI(os.Args[1:], bare, ch))
}

func exportKitRoot() {
	if strings.TrimSpace(os.Getenv("SUBSTRATE_KIT_ROOT")) != "" {
		return
	}
	root, err := kit.Root()
	if err != nil {
		return
	}
	_ = os.Setenv("SUBSTRATE_KIT_ROOT", root)
}

func ensureEngineAlias() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	alias := filepath.Join(filepath.Dir(exe), "substrate-engine")
	if _, err := os.Lstat(alias); err == nil {
		return
	}
	_ = os.Symlink(exe, alias)
}

func runCLI(args []string, installVersion, ch string) int {
	ensureEngineAlias()
	root, err := kit.Root()
	if err != nil {
		fmt.Fprintf(os.Stderr, "substrate: cannot materialize the embedded kit: %v\n", err)
		return 2
	}
	shim, err := kit.EngineShim(root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "substrate: cannot install the engine shim: %v\n", err)
		return 2
	}
	cli := filepath.Join(root, "bin", "substrate")
	if err := ensureExecutable(cli); err != nil {
		fmt.Fprintf(os.Stderr, "substrate: kit materialization at %s is not executable — set SUBSTRATE_KIT_CACHE to a non-noexec directory\n", root)
		return 2
	}

	cmd := exec.Command(cli, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(),
		"SUBSTRATE_KIT_ROOT="+root,
		"SUBSTRATE_ENGINE_BIN="+shim,
		"SUBSTRATE_KIT_SOURCE="+ch,
		"SUBSTRATE_KIT_REVISION="+kitRevision,
		"SUBSTRATE_KIT_VERSION="+installVersion,
	)
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return exitErr.ExitCode()
		}
		fmt.Fprintf(os.Stderr, "substrate: kit materialization at %s is not executable — set SUBSTRATE_KIT_CACHE to a non-noexec directory\n", root)
		return 2
	}
	return 0
}

func ensureExecutable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("stat %s: %w", path, err)
	}
	if info.Mode()&0o111 == 0 {
		return fmt.Errorf("%s is not executable", path)
	}
	return nil
}
