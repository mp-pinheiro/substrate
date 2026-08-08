package gate

import "fmt"

func FormatDuration(ms int) string {
	if ms < 0 {
		return fmt.Sprintf("%dms", ms)
	}
	if ms >= 1000 {
		return fmt.Sprintf("%d.%01ds", ms/1000, ms%1000/100)
	}
	return fmt.Sprintf("%dms", ms)
}
