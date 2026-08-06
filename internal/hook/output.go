package hook

import "github.com/mp-pinheiro/substrate/internal/logx"

// writeResult renders exact bytes with no reformatting: hook stdout/stderr
// are frozen artifacts the A/B harness compares byte-for-byte.
func writeResult(stdout, stderr []byte) {
	if len(stdout) > 0 {
		logx.Out().Print(string(stdout))
	}
	if len(stderr) > 0 {
		logx.Err().Print(string(stderr))
	}
}
