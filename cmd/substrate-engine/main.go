package main

import (
	"context"
	"fmt"
	"os"

	"github.com/mp-pinheiro/substrate/internal/hook"
)

var version = "0.0.0-dev"

func main() {
	os.Exit(run(os.Args[1:]))
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
	case "hook":
		if len(args) < 2 {
			fmt.Fprintf(os.Stderr, "usage: substrate-engine hook <name> [args]\n")
			return 2
		}
		hook.EngineVersion = version
		return hook.Dispatch(context.Background(), args[1], args[2:], os.Stdin)
	default:
		fmt.Fprintf(os.Stderr, "substrate-engine: unknown command: %s\n", args[0])
		return 2
	}
}
