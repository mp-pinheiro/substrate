package main

import (
	"context"
	"fmt"
	"os"
	"sort"

	"github.com/mp-pinheiro/substrate/internal/enginepin"
	"github.com/mp-pinheiro/substrate/internal/gate"
	"github.com/mp-pinheiro/substrate/internal/hook"
	"github.com/mp-pinheiro/substrate/internal/receipt"
	"github.com/mp-pinheiro/substrate/internal/transaction"
)

var version = "0.0.0-dev"

func main() {
	code := run(os.Args[1:])
	_ = os.Stdout.Sync()
	os.Exit(code)
}

func run(args []string) int {
	if len(args) == 0 {
		fmt.Fprintf(os.Stderr, "usage: substrate-engine <command> [args]\n")
		return 2
	}
	switch args[0] {
	case "version":
		if _, err := fmt.Fprintf(os.Stdout, "%s\n", version); err != nil {
			fmt.Fprintf(os.Stderr, "substrate-engine: %v\n", err)
			return 2
		}
		return 0
	case "receipt":
		return receipt.Dispatch(context.Background(), args[1:])
	case "gitleaks-deep-key":
		return runGitleaksDeepKey()
	case "pin":
		return runPin(args[1:])
	case "hook":
		if len(args) < 2 {
			fmt.Fprintf(os.Stderr, "usage: substrate-engine hook <name> [args]\n")
			return 2
		}
		hook.EngineVersion = version
		return hook.Dispatch(context.Background(), args[1], args[2:], os.Stdin)
	case "gate":
		rc := gate.Run(context.Background(), args[1:])
		if rc == 12 {
			return 2
		}
		return rc
	case "checkpoint":
		rc := transaction.RunCheckpoint(context.Background(), args[1:])
		if rc == transaction.ExitPreflight {
			return 2
		}
		return rc
	case "restructure":
		rc := transaction.RunRestructure(context.Background(), args[1:])
		if rc == transaction.ExitPreflight {
			return 2
		}
		return rc
	case "capabilities":
		caps := []string{"capabilities", "checkpoint", "gate", "gitleaks-deep-key", "hook", "pin", "receipt", "restructure", "version"}
		sort.Strings(caps)
		for _, c := range caps {
			if _, err := fmt.Fprintf(os.Stdout, "%s\n", c); err != nil {
				fmt.Fprintf(os.Stderr, "substrate-engine: %v\n", err)
				return 2
			}
		}
		return 0
	default:
		fmt.Fprintf(os.Stderr, "substrate-engine: unknown command: %s\n", args[0])
		return 2
	}
}

func runGitleaksDeepKey() int {
	repoRoot, err := os.Getwd()
	if err != nil {
		return fail(err)
	}
	key, err := receipt.GitleaksDeepKey(context.Background(), repoRoot)
	if err != nil {
		return fail(err)
	}
	return printLine(key)
}

func runPin(args []string) int {
	if len(args) < 1 || args[0] != "emit" {
		fmt.Fprintf(os.Stderr, "usage: substrate-engine pin emit\n")
		return 1
	}
	exePath, err := os.Executable()
	if err != nil {
		return fail(err)
	}
	pin, err := enginepin.Emit(exePath, version)
	if err != nil {
		return fail(err)
	}
	return printLine(string(pin))
}

func printLine(s string) int {
	if _, err := fmt.Fprintf(os.Stdout, "%s\n", s); err != nil {
		return fail(err)
	}
	return 0
}

func fail(err error) int {
	fmt.Fprintf(os.Stderr, "substrate-engine: %v\n", err)
	return 1
}
