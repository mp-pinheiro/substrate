package hook

import (
	"context"
	"io"

	"github.com/mp-pinheiro/substrate/internal/lifecycle"
)

func dispatchLifecycle(ctx context.Context, e env, args []string, stdin io.Reader) int {
	repo, err := e.repo()
	if err != nil {
		return 0
	}
	eng := lifecycle.New(e.paths(), repo)
	res := eng.Run(ctx, args, stdin)
	writeResult(res.Stdout, res.Stderr)
	return res.Code
}
