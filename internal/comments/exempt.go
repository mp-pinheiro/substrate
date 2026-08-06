package comments

import (
	"regexp"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/config"
)

var (
	shellcheckRe = regexp.MustCompile(`^[[:space:]]*#[[:space:]]*shellcheck`)
	todoRemoveRe = regexp.MustCompile(`todo:?[[:space:]]remove[[:space:]]in[[:space:]]`)
)

func buildAllowTagsRegex(cfg *config.Config) *regexp.Regexp {
	if cfg == nil || len(cfg.CommentTags) == 0 {
		return nil
	}
	pattern := "^[[:space:]]*(" + strings.Join(cfg.CommentTags, "|") + ")"
	re, err := regexp.Compile(pattern)
	if err != nil {
		return nil
	}
	return re
}

func isExempt(text string, allowTagsRe *regexp.Regexp) bool {
	if strings.HasPrefix(text, "#!") {
		return true
	}
	if strings.Contains(text, "gate:allow-") {
		return true
	}
	if shellcheckRe.MatchString(text) {
		return true
	}
	if strings.Contains(text, "SPDX-License-Identifier") {
		return true
	}
	lower := strings.ToLower(text)
	if todoRemoveRe.MatchString(lower) {
		return true
	}
	if allowTagsRe != nil {
		stripped := strings.TrimLeft(text, "#/- ")
		if allowTagsRe.MatchString(stripped) {
			return true
		}
	}
	return false
}
