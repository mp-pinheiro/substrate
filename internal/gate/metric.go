package gate

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"unicode"
)

type Number struct {
	Raw    json.RawMessage
	IsNull bool
	Sign   int
	Digits string
	Exp    int
}

func ParseNumber(raw json.RawMessage) (Number, error) {
	n := Number{Raw: raw}
	s := strings.TrimSpace(string(raw))
	if s == "null" {
		n.IsNull = true
		return n, nil
	}
	upper := strings.ToUpper(s)
	isNeg := false
	rest := upper
	if strings.HasPrefix(rest, "-") {
		isNeg = true
		rest = rest[1:]
	}
	rest = strings.TrimPrefix(rest, "+")
	eIdx := strings.IndexAny(rest, "E")
	var digits, expStr string
	if eIdx >= 0 {
		digits = rest[:eIdx]
		expStr = rest[eIdx+1:]
	} else {
		digits = rest
	}
	dotIdx := strings.IndexByte(digits, '.')
	if dotIdx >= 0 {
		digits = digits[:dotIdx] + digits[dotIdx+1:]
	}
	digits = strings.TrimLeft(digits, "0")
	if digits == "" {
		digits = "0"
	}
	exp := 0
	if eIdx >= 0 {
		expSign := 1
		if strings.HasPrefix(expStr, "-") {
			expSign = -1
			expStr = expStr[1:]
		} else if strings.HasPrefix(expStr, "+") {
			expStr = expStr[1:]
		}
		e, err := strconv.Atoi(expStr)
		if err != nil {
			return n, fmt.Errorf("parse exponent %q: %w", expStr, err)
		}
		exp = e * expSign
	}
	if dotIdx >= 0 {
		fracLen := eIdx - dotIdx - 1
		if eIdx < 0 {
			fracLen = len(rest) - dotIdx - 1
		}
		exp -= fracLen
	}
	trimmedLen := len(digits)
	digits = strings.TrimRight(digits, "0")
	exp += trimmedLen - len(digits)
	if digits == "" {
		digits = "0"
	}
	sign := 1
	if isNeg {
		sign = -1
	}
	if digits == "0" {
		sign = 0
	}
	n.Sign = sign
	n.Digits = digits
	n.Exp = exp
	return n, nil
}

func (n Number) Cmp(other Number) int {
	if n.IsNull && other.IsNull {
		return 0
	}
	if n.IsNull {
		return -1
	}
	if other.IsNull {
		return 1
	}
	if n.Sign != other.Sign {
		if n.Sign < other.Sign {
			return -1
		}
		return 1
	}
	if n.Sign == 0 && other.Sign == 0 {
		return 0
	}
	adjExpN := n.Exp + len(n.Digits)
	adjExpO := other.Exp + len(other.Digits)
	if n.Sign > 0 {
		if adjExpN != adjExpO {
			if adjExpN < adjExpO {
				return -1
			}
			return 1
		}
	} else {
		if adjExpN != adjExpO {
			if adjExpN < adjExpO {
				return 1
			}
			return -1
		}
	}
	digN := n.Digits
	digO := other.Digits
	maxLen := len(digN)
	if len(digO) > maxLen {
		maxLen = len(digO)
	}
	digN = digN + strings.Repeat("0", maxLen-len(digN))
	digO = digO + strings.Repeat("0", maxLen-len(digO))
	for i := range maxLen {
		if digN[i] != digO[i] {
			diff := int(digN[i]) - int(digO[i])
			if n.Sign < 0 {
				diff = -diff
			}
			if diff < 0 {
				return -1
			}
			return 1
		}
	}
	return 0
}

func (n Number) Float64() float64 {
	if n.IsNull {
		return math.NaN()
	}
	if n.Sign == 0 {
		return 0
	}
	f, err := strconv.ParseFloat(string(n.Raw), 64)
	if err != nil {
		if n.Sign < 0 {
			return math.Inf(-1)
		}
		return math.Inf(1)
	}
	return f
}
func (n Number) MarshalJSON() ([]byte, error) {
	if n.IsNull {
		return []byte("null"), nil
	}
	if n.Raw != nil {
		return n.Raw, nil
	}
	if n.Sign == 0 {
		return []byte("0"), nil
	}
	var b strings.Builder
	if n.Sign < 0 {
		b.WriteByte('-')
	}
	b.WriteByte(n.Digits[0])
	if len(n.Digits) > 1 {
		b.WriteByte('.')
		b.WriteString(n.Digits[1:])
	}
	adjExp := n.Exp + len(n.Digits) - 1
	if adjExp != 0 {
		b.WriteByte('E')
		if adjExp > 0 {
			b.WriteByte('+')
		}
		b.WriteString(strconv.Itoa(adjExp))
	}
	return []byte(b.String()), nil
}

func MustParseNumber(raw json.RawMessage) Number {
	n, err := ParseNumber(raw)
	if err != nil {
		return Number{IsNull: true}
	}
	return n
}

func parseNumberString(s string) (Number, error) {
	var raw json.RawMessage
	if s == "null" {
		raw = json.RawMessage("null")
	} else {
		cleaned := strings.TrimLeft(s, " \t\r\n")
		cleaned = strings.Map(func(r rune) rune {
			if unicode.IsSpace(r) {
				return -1
			}
			return r
		}, cleaned)
		raw = json.RawMessage(cleaned)
	}
	return ParseNumber(raw)
}

func NumberMin(a, b Number) Number {
	if a.Cmp(b) <= 0 {
		return a
	}
	return b
}

func NumberMax(a, b Number) Number {
	if a.Cmp(b) <= 0 {
		return b
	}
	return a
}

func readMetricFile(path string, includeMaxFileLines bool) (map[string]Number, map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, fmt.Errorf("read metrics: %w", err)
	}
	metrics := make(map[string]Number)
	directions := make(map[string]string)
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		var record struct {
			Name  string          `json:"name"`
			Value json.RawMessage `json:"value"`
			Dir   string          `json:"dir"`
		}
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			continue
		}
		if record.Name == "max_file_lines" && !includeMaxFileLines {
			continue
		}
		if record.Dir != "" {
			directions[record.Name] = record.Dir
		}
		number, err := ParseNumber(record.Value)
		if err != nil {
			continue
		}
		metrics[record.Name] = number
	}
	return metrics, directions, nil
}
