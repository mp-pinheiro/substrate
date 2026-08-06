package comments

import (
	"fmt"
	"regexp"
	"strings"
)

const (
	restatesCodeTpl = `(^|[[:space:]])%M%[[:space:]]*(fetch|get|set|create|update|delete|initialise|initialize|loop|iterate|check|validate|return|call|add|remove|handle|process|parse|build|render|start|stop|store|save|load|print|log|convert|ensure|apply|execute)[[:space:]]+[[:alnum:]]`
	narrationTpl    = `(^|[[:space:]])%M%[[:space:]]*(we[[:space:]]|let'?s[[:space:]]|now[[:space:]]|then[[:space:]]|note that|here we|this (is|will|does|function|method|block)|as (mentioned|noted|described|above))`
	stepNumberTpl   = `(^|[[:space:]])%M%[[:space:]]*(step[[:space:]]*[0-9]|[0-9]+\.[[:space:]]+[[:alnum:]])`
	bannerTpl       = `^[[:space:]]*%M%[[:space:]]*[=*_~-]{3,}`
	todoTpl         = `(^|[[:space:]])%M%[[:space:]]*(todo|fixme|xxx|placeholder|for now|temporar|stub[[:space:]:])`
)

var patternNames = [3]string{"restates-code", "narration", "step-numbering"}
var patternTemplates = [3]string{restatesCodeTpl, narrationTpl, stepNumberTpl}

var (
	causalRegex         = regexp.MustCompile(`because|so that|since[[:space:]]|otherwise|prevents|refuses|needs|requires|doesn'?t|does not|won'?t|can'?t|cannot|\(`)
	bannerFallbackRegex = regexp.MustCompile(`^[[:space:]]*[=*_~-]{4,}[[:space:]]*$`)
	funcdefRegex        = regexp.MustCompile(`^[[:alnum:]_-]+[[:space:]]*\(\)[[:space:]]*\{`)
)

type regexBundle struct {
	banner      *regexp.Regexp
	todo        *regexp.Regexp
	patterns    [3]*regexp.Regexp
	fullLineAST *regexp.Regexp
	fullLineLM  *regexp.Regexp
}

func markersAlt(markers []string) string {
	filtered := make([]string, 0, len(markers))
	for _, m := range markers {
		if m != "" {
			filtered = append(filtered, m)
		}
	}
	if len(filtered) == 0 {
		filtered = []string{"#"}
	}
	joined := strings.Join(filtered, "|")
	return strings.ReplaceAll(joined, "*", `\*`)
}

func buildBundle(markers []string) (*regexBundle, error) {
	paren := "(" + markersAlt(markers) + ")"
	b := &regexBundle{}
	var err error
	if b.banner, err = regexp.Compile(strings.Replace(bannerTpl, "%M%", paren, 1)); err != nil {
		return nil, fmt.Errorf("comments: compile banner regex: %w", err)
	}
	if b.todo, err = regexp.Compile(strings.Replace(todoTpl, "%M%", paren, 1)); err != nil {
		return nil, fmt.Errorf("comments: compile todo regex: %w", err)
	}
	for i, tpl := range patternTemplates {
		re, cerr := regexp.Compile(strings.Replace(tpl, "%M%", paren, 1))
		if cerr != nil {
			return nil, fmt.Errorf("comments: compile %s regex: %w", patternNames[i], cerr)
		}
		b.patterns[i] = re
	}
	if b.fullLineAST, err = regexp.Compile(`^[[:space:]]*` + paren); err != nil {
		return nil, fmt.Errorf("comments: compile ast fullline regex: %w", err)
	}
	if b.fullLineLM, err = regexp.Compile(`^` + paren); err != nil {
		return nil, fmt.Errorf("comments: compile line-mode fullline regex: %w", err)
	}
	return b, nil
}
