package canonjson

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

// Marshal renders v exactly as `jq -c` would produce it.
func Marshal(v Value) ([]byte, error) {
	var buf []byte
	buf, err := appendValue(buf, v, false)
	if err != nil {
		return nil, err
	}
	return buf, nil
}

// MarshalSorted renders v exactly as `jq -cS` would produce it.
func MarshalSorted(v Value) ([]byte, error) {
	var buf []byte
	buf, err := appendValue(buf, v, true)
	if err != nil {
		return nil, err
	}
	return buf, nil
}

func appendValue(buf []byte, v Value, sorted bool) ([]byte, error) {
	switch val := v.(type) {
	case nil:
		return append(buf, "null"...), nil
	case bool:
		if val {
			return append(buf, "true"...), nil
		}
		return append(buf, "false"...), nil
	case string:
		return appendString(buf, val), nil
	case int64:
		return strconv.AppendInt(buf, val, 10), nil
	case float64:
		return appendFloat(buf, val), nil
	case Number:
		return appendNumber(buf, val), nil
	case *Object:
		return appendObject(buf, val, sorted)
	case []Value:
		return appendArray(buf, val, sorted)
	default:
		return nil, fmt.Errorf("canonjson: unsupported value type %T", v)
	}
}

func appendObject(buf []byte, o *Object, sorted bool) ([]byte, error) {
	if o == nil {
		return append(buf, "null"...), nil
	}
	buf = append(buf, '{')
	keys := o.keys
	if sorted {
		keys = o.Keys()
		sort.Strings(keys)
	}
	var err error
	for i, k := range keys {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf = appendString(buf, k)
		buf = append(buf, ':')
		buf, err = appendValue(buf, o.values[k], sorted)
		if err != nil {
			return nil, err
		}
	}
	return append(buf, '}'), nil
}

func appendArray(buf []byte, a []Value, sorted bool) ([]byte, error) {
	buf = append(buf, '[')
	var err error
	for i, v := range a {
		if i > 0 {
			buf = append(buf, ',')
		}
		buf, err = appendValue(buf, v, sorted)
		if err != nil {
			return nil, err
		}
	}
	return append(buf, ']'), nil
}

const hexDigits = "0123456789abcdef"

func appendString(buf []byte, s string) []byte {
	s = SanitizeUTF8(s)
	buf = append(buf, '"')
	b := []byte(s)
	for i := 0; i < len(b); {
		cp, n := decodeUTF8(b[i:])
		switch {
		case cp == '"' || cp == '\\':
			buf = append(buf, '\\', byte(cp))
		case cp >= 0x20 && cp <= 0x7E:
			buf = append(buf, byte(cp))
		case cp == '\b':
			buf = append(buf, '\\', 'b')
		case cp == '\t':
			buf = append(buf, '\\', 't')
		case cp == '\r':
			buf = append(buf, '\\', 'r')
		case cp == '\n':
			buf = append(buf, '\\', 'n')
		case cp == '\f':
			buf = append(buf, '\\', 'f')
		case cp < 0x20 || cp == 0x7F:
			buf = appendUnicodeEscape(buf, cp)
		default:
			buf = append(buf, b[i:i+n]...)
		}
		i += n
	}
	return append(buf, '"')
}

func appendUnicodeEscape(buf []byte, cp rune) []byte {
	if cp <= 0xFFFF {
		return appendU4(buf, uint32(cp))
	}
	cp -= 0x10000
	buf = appendU4(buf, 0xD800|(uint32(cp)>>10)&0x3ff)
	return appendU4(buf, 0xDC00|uint32(cp)&0x3ff)
}

func appendU4(buf []byte, v uint32) []byte {
	buf = append(buf, '\\', 'u')
	buf = append(buf, hexDigits[(v>>12)&0xf], hexDigits[(v>>8)&0xf], hexDigits[(v>>4)&0xf], hexDigits[v&0xf])
	return buf
}

// Mirrors jq's jvp_dtoa_fmt (src/jv_dtoa.c) exponential-form thresholds exactly.
func appendFloat(buf []byte, f float64) []byte {
	if math.IsNaN(f) {
		return append(buf, "null"...)
	}
	if f > math.MaxFloat64 {
		f = math.MaxFloat64
	}
	if f < -math.MaxFloat64 {
		f = -math.MaxFloat64
	}

	neg := math.Signbit(f)
	af := f
	if neg {
		af = -f
	}

	sci := strconv.AppendFloat(nil, af, 'e', -1, 64)
	mantissa, expPart, _ := strings.Cut(string(sci), "e")
	exp, _ := strconv.Atoi(expPart)
	digits := strings.Replace(mantissa, ".", "", 1)
	decpt := exp + 1

	if neg {
		buf = append(buf, '-')
	}
	switch {
	case decpt <= -4 || decpt > len(digits)+15:
		buf = append(buf, digits[0])
		if len(digits) > 1 {
			buf = append(buf, '.')
			buf = append(buf, digits[1:]...)
		}
		buf = append(buf, 'e')
		e := decpt - 1
		if e < 0 {
			buf = append(buf, '-')
			e = -e
		} else {
			buf = append(buf, '+')
		}
		es := strconv.Itoa(e)
		if len(es) < 2 {
			es = "0" + es
		}
		buf = append(buf, es...)
	case decpt <= 0:
		buf = append(buf, '0', '.')
		buf = append(buf, strings.Repeat("0", -decpt)...)
		buf = append(buf, digits...)
	case decpt >= len(digits):
		buf = append(buf, digits...)
		buf = append(buf, strings.Repeat("0", decpt-len(digits))...)
	default:
		buf = append(buf, digits[:decpt]...)
		buf = append(buf, '.')
		buf = append(buf, digits[decpt:]...)
	}
	return buf
}

// Mirrors jq 1.7.1's decNumber toString (General Decimal Arithmetic Spec) formatting.
func appendNumber(buf []byte, n Number) []byte {
	digits := n.digits
	length := len(digits)
	adjusted := n.exponent + length - 1

	if n.neg {
		buf = append(buf, '-')
	}
	if n.exponent <= 0 && adjusted >= -6 {
		position := length + n.exponent
		switch {
		case position <= 0:
			buf = append(buf, '0', '.')
			buf = append(buf, strings.Repeat("0", -position)...)
			buf = append(buf, digits...)
		case position >= length:
			buf = append(buf, digits...)
		default:
			buf = append(buf, digits[:position]...)
			buf = append(buf, '.')
			buf = append(buf, digits[position:]...)
		}
		return buf
	}

	buf = append(buf, digits[0])
	if length > 1 {
		buf = append(buf, '.')
		buf = append(buf, digits[1:]...)
	}
	buf = append(buf, 'E')
	if adjusted >= 0 {
		buf = append(buf, '+')
	} else {
		buf = append(buf, '-')
		adjusted = -adjusted
	}
	return strconv.AppendInt(buf, int64(adjusted), 10)
}
