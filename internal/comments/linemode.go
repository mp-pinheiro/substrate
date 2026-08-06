package comments

import (
	"strings"

	"github.com/mp-pinheiro/substrate/internal/config"
)

type lmState struct {
	markers []string
	bo, bc  string
	heredoc bool
	inBlock bool
	hdTag   string
}

func newLMState(entry config.LangEntry) *lmState {
	s := &lmState{markers: entry.Markers, heredoc: entry.Heredoc}
	if len(entry.Block) > 0 {
		s.bo = entry.Block[0][0]
		s.bc = entry.Block[0][1]
	}
	return s
}

func (s *lmState) scan(line string) (text string, fromBlock bool) {
	if s.hdTag != "" {
		if trimLeadingSpace(line) == s.hdTag {
			s.hdTag = ""
		}
		return "", false
	}
	if s.inBlock {
		if idx := strings.Index(line, s.bc); idx >= 0 {
			s.inBlock = false
			return line[:idx], true
		}
		return line, true
	}
	if !s.probe(line) {
		return "", false
	}
	return s.scanChars(line)
}

func (s *lmState) probe(line string) bool {
	for _, m := range s.markers {
		if strings.Contains(line, m) {
			return true
		}
	}
	if s.bo != "" && strings.Contains(line, s.bo) {
		return true
	}
	if s.heredoc && strings.Contains(line, "<<") {
		return true
	}
	return false
}

func (s *lmState) scanChars(line string) (string, bool) {
	runes := []rune(line)
	n := len(runes)
	inS, inD := false, false
	for i := 0; i < n; {
		c := runes[i]
		if inS {
			if c == '\'' {
				inS = false
			}
			i++
			continue
		}
		if inD {
			if c == '\\' {
				i += 2
				continue
			}
			if c == '"' {
				inD = false
			}
			i++
			continue
		}
		if c == '\'' {
			inS = true
			i++
			continue
		}
		if c == '"' {
			inD = true
			i++
			continue
		}
		if s.heredoc && i+1 < n && c == '<' && runes[i+1] == '<' {
			if s.tryHeredoc(runes[i+2:]) {
				return "", false
			}
			i += 2
			continue
		}
		if s.bo != "" && matchesAt(runes, i, s.bo) {
			body := string(runes[i+len([]rune(s.bo)):])
			if idx := strings.Index(body, s.bc); idx >= 0 {
				return body[:idx], true
			}
			s.inBlock = true
			return body, true
		}
		if text, ok := s.matchMarker(runes, i); ok {
			return text, false
		}
		i++
	}
	return "", false
}

func (s *lmState) matchMarker(runes []rune, i int) (string, bool) {
	for _, m := range s.markers {
		if matchesAt(runes, i, m) {
			return string(runes[i:]), true
		}
	}
	return "", false
}

func (s *lmState) tryHeredoc(rest []rune) bool {
	str := strings.TrimPrefix(string(rest), "-")
	str = trimLeadingSpace(str)
	str = strings.TrimPrefix(str, `"`)
	str = strings.TrimPrefix(str, `'`)
	tag := leadingWordChars(str)
	if tag == "" {
		return false
	}
	s.hdTag = tag
	return true
}

func matchesAt(runes []rune, i int, m string) bool {
	mr := []rune(m)
	if i+len(mr) > len(runes) {
		return false
	}
	for k, r := range mr {
		if runes[i+k] != r {
			return false
		}
	}
	return true
}

func leadingWordChars(s string) string {
	i := 0
	for i < len(s) {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' {
			i++
			continue
		}
		break
	}
	return s[:i]
}
