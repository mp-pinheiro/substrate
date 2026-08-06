package policy

import (
	"os"
	"strings"
)

const maxSymlinkDepth = 40

// WHY: matches GNU `readlink -f` — every component is resolved through
// symlinks, but only the final component is allowed to not exist.
func readlinkF(path string) (string, bool) {
	if !strings.HasPrefix(path, "/") {
		return "", false
	}
	queue := splitPathComponents(path)
	resolved := ""
	links := 0
	for len(queue) > 0 {
		comp := queue[0]
		queue = queue[1:]
		switch comp {
		case "", ".":
			continue
		case "..":
			if idx := strings.LastIndexByte(resolved, '/'); idx >= 0 {
				resolved = resolved[:idx]
			} else {
				resolved = ""
			}
			continue
		}
		candidate := resolved + "/" + comp
		info, err := os.Lstat(candidate)
		if err != nil {
			if len(queue) == 0 {
				resolved = candidate
				break
			}
			return "", false
		}
		if info.Mode()&os.ModeSymlink != 0 {
			links++
			if links > maxSymlinkDepth {
				return "", false
			}
			target, rerr := os.Readlink(candidate)
			if rerr != nil {
				return "", false
			}
			if strings.HasPrefix(target, "/") {
				resolved = ""
			}
			queue = append(splitPathComponents(target), queue...)
			continue
		}
		resolved = candidate
	}
	if resolved == "" {
		resolved = "/"
	}
	return resolved, true
}

func splitPathComponents(path string) []string {
	parts := strings.Split(path, "/")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
