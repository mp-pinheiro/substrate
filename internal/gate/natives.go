package gate

var NativeRuns = map[string]RunFn{
	"05-unclaimed-source.sh": check05Unclaimed,
	"10-comments.sh":         check10Comments,
	"15-tracking.sh":         check15Tracking,
	"30-budgets.sh":          check30Budgets,
	"40-data-validity.sh":    check40DataValidity,
}
