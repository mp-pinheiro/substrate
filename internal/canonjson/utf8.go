package canonjson

// WHY: mirrors jq's utf8_coding_length[] sentinel (src/jv_utf8_tables.h).
const continuationByte = 0xff

var utf8CodingLength = buildUTF8CodingLength()
var utf8CodingBits = buildUTF8CodingBits()
var utf8FirstCodepoint = [5]rune{0x00, 0x00, 0x80, 0x800, 0x10000}

func buildUTF8CodingLength() [256]byte {
	var t [256]byte
	for i := range 0x80 {
		t[i] = 1
	}
	for i := 0x80; i < 0xC0; i++ {
		t[i] = continuationByte
	}
	for i := 0xC2; i < 0xE0; i++ {
		t[i] = 2
	}
	for i := 0xE0; i < 0xF0; i++ {
		t[i] = 3
	}
	for i := 0xF0; i <= 0xF4; i++ {
		t[i] = 4
	}
	return t
}

func buildUTF8CodingBits() [256]byte {
	var t [256]byte
	for i := range 0x80 {
		t[i] = 0x7f
	}
	for i := 0x80; i < 0xC0; i++ {
		t[i] = 0x3f
	}
	for i := 0xC2; i < 0xE0; i++ {
		t[i] = 0x1f
	}
	for i := 0xE0; i < 0xF0; i++ {
		t[i] = 0x0f
	}
	for i := 0xF0; i <= 0xF4; i++ {
		t[i] = 0x07
	}
	return t
}

// WHY: matches jq's jvp_utf8_next "maximal subpart" rule exactly, so an
// invalid multi-byte prefix collapses to one U+FFFD, not one per byte.
func decodeUTF8(s []byte) (rune, int) {
	first := s[0]
	if first < 0x80 {
		return rune(first), 1
	}
	length := int(utf8CodingLength[first])
	if length == 0 || length == continuationByte {
		return -1, 1
	}
	if length > len(s) {
		return -1, len(s)
	}
	cp := rune(first) & rune(utf8CodingBits[first])
	for i := 1; i < length; i++ {
		ch := s[i]
		if utf8CodingLength[ch] != continuationByte {
			return -1, i
		}
		cp = (cp << 6) | (rune(ch) & 0x3f)
	}
	if cp < utf8FirstCodepoint[length] {
		return -1, length
	}
	if cp >= 0xD800 && cp <= 0xDFFF {
		return -1, length
	}
	if cp > 0x10FFFF {
		return -1, length
	}
	return cp, length
}

// SanitizeUTF8 replaces each invalid byte run in s with a single U+FFFD,
// matching jq 1.7's string construction (jv_string_sized).
func SanitizeUTF8(s string) string {
	b := []byte(s)
	valid := true
	for i := 0; i < len(b); {
		cp, n := decodeUTF8(b[i:])
		if cp == -1 {
			valid = false
			break
		}
		i += n
	}
	if valid {
		return s
	}

	out := make([]byte, 0, len(b))
	for i := 0; i < len(b); {
		cp, n := decodeUTF8(b[i:])
		if cp == -1 {
			out = append(out, "\ufffd"...)
		} else {
			out = append(out, b[i:i+n]...)
		}
		i += n
	}
	return string(out)
}
