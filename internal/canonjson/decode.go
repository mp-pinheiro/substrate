package canonjson

import (
	"fmt"
	"strconv"
)

// Unmarshal sanitizes invalid UTF-8 the same way jq's parser does.
func Unmarshal(data []byte) (Value, error) {
	p := &parser{data: data}
	p.skipWhitespace()
	v, err := p.parseValue()
	if err != nil {
		return nil, err
	}
	p.skipWhitespace()
	if p.pos != len(p.data) {
		return nil, fmt.Errorf("canonjson: unexpected trailing data at offset %d", p.pos)
	}
	return v, nil
}

type parser struct {
	data []byte
	pos  int
}

func (p *parser) errorf(format string, args ...any) error {
	return fmt.Errorf("canonjson: "+format+" at offset %d", append(args, p.pos)...)
}

func (p *parser) skipWhitespace() {
	for p.pos < len(p.data) {
		switch p.data[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		default:
			return
		}
	}
}

func (p *parser) parseValue() (Value, error) {
	if p.pos >= len(p.data) {
		return nil, p.errorf("unexpected end of input")
	}
	switch c := p.data[p.pos]; {
	case c == '{':
		return p.parseObject()
	case c == '[':
		return p.parseArray()
	case c == '"':
		return p.parseString()
	case c == 't':
		return p.parseLiteral("true", true)
	case c == 'f':
		return p.parseLiteral("false", false)
	case c == 'n':
		return p.parseLiteral("null", nil)
	case c == '-' || (c >= '0' && c <= '9'):
		return p.parseNumber()
	default:
		return nil, p.errorf("unexpected character %q", c)
	}
}

func (p *parser) parseLiteral(lit string, v Value) (Value, error) {
	if p.pos+len(lit) > len(p.data) || string(p.data[p.pos:p.pos+len(lit)]) != lit {
		return nil, p.errorf("invalid literal, expected %q", lit)
	}
	p.pos += len(lit)
	return v, nil
}

func (p *parser) parseObject() (Value, error) {
	p.pos++
	obj := NewObject()
	p.skipWhitespace()
	if p.pos < len(p.data) && p.data[p.pos] == '}' {
		p.pos++
		return obj, nil
	}
	for {
		p.skipWhitespace()
		if p.pos >= len(p.data) || p.data[p.pos] != '"' {
			return nil, p.errorf("expected string key")
		}
		keyVal, err := p.parseString()
		if err != nil {
			return nil, err
		}
		key, _ := keyVal.(string)
		p.skipWhitespace()
		if p.pos >= len(p.data) || p.data[p.pos] != ':' {
			return nil, p.errorf("expected ':' after object key")
		}
		p.pos++
		p.skipWhitespace()
		v, err := p.parseValue()
		if err != nil {
			return nil, err
		}
		obj.Set(key, v)
		p.skipWhitespace()
		if p.pos >= len(p.data) {
			return nil, p.errorf("unterminated object")
		}
		switch p.data[p.pos] {
		case ',':
			p.pos++
		case '}':
			p.pos++
			return obj, nil
		default:
			return nil, p.errorf("expected ',' or '}' in object")
		}
	}
}

func (p *parser) parseArray() (Value, error) {
	p.pos++
	arr := []Value{}
	p.skipWhitespace()
	if p.pos < len(p.data) && p.data[p.pos] == ']' {
		p.pos++
		return arr, nil
	}
	for {
		p.skipWhitespace()
		v, err := p.parseValue()
		if err != nil {
			return nil, err
		}
		arr = append(arr, v)
		p.skipWhitespace()
		if p.pos >= len(p.data) {
			return nil, p.errorf("unterminated array")
		}
		switch p.data[p.pos] {
		case ',':
			p.pos++
		case ']':
			p.pos++
			return arr, nil
		default:
			return nil, p.errorf("expected ',' or ']' in array")
		}
	}
}

func (p *parser) parseString() (Value, error) {
	p.pos++
	start := p.pos
	var buf []byte
	for {
		if p.pos >= len(p.data) {
			return nil, p.errorf("unterminated string")
		}
		c := p.data[p.pos]
		switch {
		case c == '"':
			var s string
			if buf == nil {
				s = string(p.data[start:p.pos])
			} else {
				s = string(append(buf, p.data[start:p.pos]...))
			}
			p.pos++
			return SanitizeUTF8(s), nil
		case c == '\\':
			buf = append(buf, p.data[start:p.pos]...)
			decoded, err := p.parseEscape()
			if err != nil {
				return nil, err
			}
			buf = append(buf, decoded...)
			start = p.pos
		case c < 0x20:
			return nil, p.errorf("control character %#02x must be escaped in string", c)
		default:
			p.pos++
		}
	}
}

func (p *parser) parseEscape() ([]byte, error) {
	p.pos++
	if p.pos >= len(p.data) {
		return nil, p.errorf("unterminated escape sequence")
	}
	c := p.data[p.pos]
	switch c {
	case '"':
		p.pos++
		return []byte{'"'}, nil
	case '\\':
		p.pos++
		return []byte{'\\'}, nil
	case '/':
		p.pos++
		return []byte{'/'}, nil
	case 'b':
		p.pos++
		return []byte{'\b'}, nil
	case 'f':
		p.pos++
		return []byte{'\f'}, nil
	case 'n':
		p.pos++
		return []byte{'\n'}, nil
	case 'r':
		p.pos++
		return []byte{'\r'}, nil
	case 't':
		p.pos++
		return []byte{'\t'}, nil
	case 'u':
		return p.parseUnicodeEscape()
	default:
		return nil, p.errorf("invalid escape character %q", c)
	}
}

func (p *parser) parseUnicodeEscape() ([]byte, error) {
	cp, err := p.readHex4()
	if err != nil {
		return nil, err
	}
	if cp >= 0xD800 && cp <= 0xDBFF {
		if p.pos+1 < len(p.data) && p.data[p.pos] == '\\' && p.data[p.pos+1] == 'u' {
			savePos := p.pos
			p.pos++
			low, err := p.readHex4()
			if err != nil {
				return nil, err
			}
			if low >= 0xDC00 && low <= 0xDFFF {
				combined := 0x10000 + (cp-0xD800)<<10 + (low - 0xDC00)
				return encodeRuneUTF8(combined), nil
			}
			p.pos = savePos
		}
		return nil, p.errorf("invalid \\uXXXX\\uXXXX surrogate pair escape")
	}
	if cp >= 0xDC00 && cp <= 0xDFFF {
		return encodeRuneUTF8(0xFFFD), nil
	}
	return encodeRuneUTF8(cp), nil
}

func (p *parser) readHex4() (rune, error) {
	p.pos++
	if p.pos+4 > len(p.data) {
		return 0, p.errorf("truncated \\u escape")
	}
	v, err := strconv.ParseUint(string(p.data[p.pos:p.pos+4]), 16, 32)
	if err != nil {
		return 0, p.errorf("invalid \\u escape: %w", err)
	}
	p.pos += 4
	return rune(v), nil
}

func encodeRuneUTF8(r rune) []byte {
	switch {
	case r <= 0x7F:
		return []byte{byte(r)}
	case r <= 0x7FF:
		return []byte{byte(0xC0 | (r >> 6)), byte(0x80 | (r & 0x3F))}
	case r <= 0xFFFF:
		return []byte{byte(0xE0 | (r >> 12)), byte(0x80 | ((r >> 6) & 0x3F)), byte(0x80 | (r & 0x3F))}
	default:
		return []byte{
			byte(0xF0 | (r >> 18)),
			byte(0x80 | ((r >> 12) & 0x3F)),
			byte(0x80 | ((r >> 6) & 0x3F)),
			byte(0x80 | (r & 0x3F)),
		}
	}
}

func (p *parser) parseNumber() (Value, error) {
	neg := false
	if p.pos < len(p.data) && p.data[p.pos] == '-' {
		neg = true
		p.pos++
	}
	if p.pos >= len(p.data) || p.data[p.pos] < '0' || p.data[p.pos] > '9' {
		return nil, p.errorf("invalid number")
	}
	intStart := p.pos
	if p.data[p.pos] == '0' {
		p.pos++
	} else {
		for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
			p.pos++
		}
	}
	intDigits := string(p.data[intStart:p.pos])

	fracDigits := ""
	if p.pos < len(p.data) && p.data[p.pos] == '.' {
		p.pos++
		fracStart := p.pos
		if p.pos >= len(p.data) || p.data[p.pos] < '0' || p.data[p.pos] > '9' {
			return nil, p.errorf("invalid number: missing digits after decimal point")
		}
		for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
			p.pos++
		}
		fracDigits = string(p.data[fracStart:p.pos])
	}

	explicitExp := 0
	if p.pos < len(p.data) && (p.data[p.pos] == 'e' || p.data[p.pos] == 'E') {
		p.pos++
		expNeg := false
		if p.pos < len(p.data) && (p.data[p.pos] == '+' || p.data[p.pos] == '-') {
			expNeg = p.data[p.pos] == '-'
			p.pos++
		}
		expStart := p.pos
		if p.pos >= len(p.data) || p.data[p.pos] < '0' || p.data[p.pos] > '9' {
			return nil, p.errorf("invalid number: missing digits in exponent")
		}
		for p.pos < len(p.data) && p.data[p.pos] >= '0' && p.data[p.pos] <= '9' {
			p.pos++
		}
		expVal, err := strconv.Atoi(string(p.data[expStart:p.pos]))
		if err != nil {
			// jq accepts exponents wider than a machine int; clamp instead of erroring.
			expVal = 1 << 30
		}
		if expNeg {
			expVal = -expVal
		}
		explicitExp = expVal
	}

	return Number{
		neg:      neg,
		digits:   stripLeadingZeros(intDigits + fracDigits),
		exponent: explicitExp - len(fracDigits),
	}, nil
}

func stripLeadingZeros(digits string) string {
	i := 0
	for i < len(digits)-1 && digits[i] == '0' {
		i++
	}
	return digits[i:]
}
