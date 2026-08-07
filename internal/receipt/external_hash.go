package receipt

import (
	"os"
	"path/filepath"
)

// computeExternalHash keeps bash's environment record minus LANG and LC_ALL, and minus
// SUBSTRATE_FILE_LIST, which BuildState refuses upstream so it is provably empty (B5/H2/H18).
func computeExternalHash() (string, error) {
	home := os.Getenv("HOME")
	bunInstall := os.Getenv("BUN_INSTALL")
	sdkRoot := bunInstall
	if sdkRoot == "" {
		sdkRoot = filepath.Join(home, ".bun")
	}
	sdk := filepath.Join(sdkRoot, "install", "global", "node_modules",
		"@oh-my-pi", "pi-coding-agent", "dist", "types", "index.d.ts")

	kind, _, value, err := fileState(sdk)
	if err != nil {
		return "", err
	}

	records := [][]byte{
		joinFields("omp-sdk", sdk, kind, value),
		joinFields("environment", "HOME="+home, "BUN_INSTALL="+bunInstall, "CI="+os.Getenv("CI")),
	}
	return hashRecords(records)
}
