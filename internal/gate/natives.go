package gate

var NativeRuns = map[string]RunFn{
	"15-tracking.sh": check15Tracking,
}
