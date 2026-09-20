package main

import (
	"os"

	"github.com/mp-pinheiro/substrate/internal/enginecli"
)

var version = "0.0.0-dev"

func main() {
	code := enginecli.Run(os.Args[1:], version)
	_ = os.Stdout.Sync()
	os.Exit(code)
}
