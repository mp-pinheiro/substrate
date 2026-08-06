package canonjson

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"math"
	"testing"
)

func marshalString(t *testing.T, s string) []byte {
	t.Helper()
	out, err := Marshal(s)
	if err != nil {
		t.Fatalf("Marshal(%q): %v", s, err)
	}
	return out
}

// WHY: expected bytes below are captured verbatim from the pinned jq 1.7.1
// (test/.toolchain/bin/jq -c/-cS/--arg/--argjson), not re-derived.
func TestMarshalControlCharsAndDEL(t *testing.T) {
	in := "\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f"
	want := "\"\\u0000\\u0001\\u0002\\u0003\\u0004\\u0005\\u0006\\u0007\\b\\t\\n\\u000b\\f\\r\\u000e\\u000f\\u0010\\u0011\\u0012\\u0013\\u0014\\u0015\\u0016\\u0017\\u0018\\u0019\\u001a\\u001b\\u001c\\u001d\\u001e\\u001f\\u007f\""
	got := marshalString(t, in)
	if string(got) != want {
		t.Errorf("Marshal(control chars) =\n%s\nwant\n%s", got, want)
	}
}

func TestMarshalSpecialASCII(t *testing.T) {
	in := "<>&/\"\\"
	want := "\"<>&/\\\"\\\\\""
	got := marshalString(t, in)
	if string(got) != want {
		t.Errorf("Marshal(%q) = %s, want %s", in, got, want)
	}
}

func TestMarshalNonASCII(t *testing.T) {
	in := "☃ 日本語 🎉"
	want := "\"☃ 日本語 🎉\""
	got := marshalString(t, in)
	if string(got) != want {
		t.Errorf("Marshal(%q) = %s, want %s", in, got, want)
	}
}

func TestSanitizeUTF8(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"overlong_nul", "\xc0\x80", "\xef\xbf\xbd\xef\xbf\xbd"},
		{"truncated_2byte", "\xc2", "\xef\xbf\xbd"},
		{"truncated_3byte", "\xe2\x98", "\xef\xbf\xbd"},
		{"lone_continuation", "\x80", "\xef\xbf\xbd"},
		{"two_lone_continuations", "\x80\x80", "\xef\xbf\xbd\xef\xbf\xbd"},
		{"truncated_4byte", "\xf0\x9f\x8e", "\xef\xbf\xbd"},
		{"0xff_byte", "\xff", "\xef\xbf\xbd"},
		{"utf8_encoded_surrogate", "\xed\xa0\x80", "\xef\xbf\xbd"},
		{"mixed_valid_invalid", "a\xffb\xc2\xa9c", "a\xef\xbf\xbdb\xc2\xa9c"},
		{"already_valid", "hello ☃", "hello ☃"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := SanitizeUTF8(c.in)
			if got != c.want {
				t.Errorf("SanitizeUTF8(%q) = %q, want %q", c.in, got, c.want)
			}
		})
	}
}

func TestMarshalInvalidUTF8(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"overlong_nul", "\xc0\x80", "\"\xef\xbf\xbd\xef\xbf\xbd\""},
		{"truncated_2byte", "\xc2", "\"\xef\xbf\xbd\""},
		{"truncated_3byte", "\xe2\x98", "\"\xef\xbf\xbd\""},
		{"lone_continuation", "\x80", "\"\xef\xbf\xbd\""},
		{"two_lone_continuations", "\x80\x80", "\"\xef\xbf\xbd\xef\xbf\xbd\""},
		{"truncated_4byte", "\xf0\x9f\x8e", "\"\xef\xbf\xbd\""},
		{"0xff_byte", "\xff", "\"\xef\xbf\xbd\""},
		{"utf8_encoded_surrogate", "\xed\xa0\x80", "\"\xef\xbf\xbd\""},
		{"mixed_valid_invalid", "a\xffb\xc2\xa9c", "\"a\xef\xbf\xbdb\xc2\xa9c\""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := marshalString(t, c.in)
			if string(got) != c.want {
				t.Errorf("Marshal(%q) = %s, want %s", c.in, got, c.want)
			}
		})
	}
}

func TestMarshalEmptyContainers(t *testing.T) {
	if got, err := Marshal(NewObject()); err != nil || string(got) != "{}" {
		t.Errorf("Marshal(empty object) = %s, %v, want {}", got, err)
	}
	if got, err := Marshal([]Value{}); err != nil || string(got) != "[]" {
		t.Errorf("Marshal(empty array) = %s, %v, want []", got, err)
	}
}

func TestMarshalSortedNested(t *testing.T) {
	obj := NewObject()
	obj.Set("b", int64(1))
	inner := NewObject()
	inner.Set("d", int64(2))
	inner.Set("c", int64(1))
	obj.Set("a", inner)
	arr1 := NewObject()
	arr1.Set("z", int64(1))
	arr1.Set("y", int64(2))
	arr2 := NewObject()
	arr2.Set("b", int64(1))
	arr2.Set("a", int64(2))
	obj.Set("arr", []Value{arr1, arr2})
	obj.Set("m", NewObject())

	wantUnsorted := `{"b":1,"a":{"d":2,"c":1},"arr":[{"z":1,"y":2},{"b":1,"a":2}],"m":{}}`
	if got, err := Marshal(obj); err != nil || string(got) != wantUnsorted {
		t.Errorf("Marshal(nested) = %s, %v, want %s", got, err, wantUnsorted)
	}

	wantSorted := `{"a":{"c":1,"d":2},"arr":[{"y":2,"z":1},{"a":2,"b":1}],"b":1,"m":{}}`
	if got, err := MarshalSorted(obj); err != nil || string(got) != wantSorted {
		t.Errorf("MarshalSorted(nested) = %s, %v, want %s", got, err, wantSorted)
	}
}

func TestMarshalIntegers(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{0, "0"},
		{-1, "-1"},
		{1, "1"},
		{42, "42"},
		{-42, "-42"},
		{1000000, "1000000"},
		{9223372036854775807, "9223372036854775807"},
		{-9223372036854775808, "-9223372036854775808"},
	}
	for _, c := range cases {
		got, err := Marshal(c.in)
		if err != nil || string(got) != c.want {
			t.Errorf("Marshal(int64(%d)) = %s, %v, want %s", c.in, got, err, c.want)
		}
	}
}

func TestMarshalFloats(t *testing.T) {
	negZero := math.Copysign(0, -1)
	a1, b1 := 0.1, 0.2
	a2, b2 := 1.1, 2.2
	cases := []struct {
		name string
		in   float64
		want string
	}{
		{"zero", 0.0, "0"},
		{"whole_five", 5.0, "5"},
		{"two_point_five", 2.5, "2.5"},
		{"negative_two_point_five", -2.5, "-2.5"},
		{"whole_hundred", 100.0, "100"},
		{"one_tenth", 0.1, "0.1"},
		{"one_e10", 1e10, "10000000000"},
		{"one_e_minus7", 1e-7, "1e-07"},
		{"one_e21", 1e21, "1e+21"},
		{"one_e_minus5", 1e-5, "1e-05"},
		{"one_point_five_e300", 1.5e300, "1.5e+300"},
		{"negative_zero", negZero, "-0"},
		{"pi_like", 3.14159265358979, "3.14159265358979"},
		{"rounding_0_1_plus_0_2", a1 + b1, "0.30000000000000004"},
		{"rounding_1_1_plus_2_2", a2 + b2, "3.3000000000000003"},
		{"one_e_minus300", 1e-300, "1e-300"},
		{"precision_loss_2_53_plus_1", 9007199254740993.0, "9007199254740992"},
		{"nan_to_null", math.NaN(), "null"},
		{"positive_infinity_clamped", math.Inf(1), "1.7976931348623157e+308"},
		{"negative_infinity_clamped", math.Inf(-1), "-1.7976931348623157e+308"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := Marshal(c.in)
			if err != nil || string(got) != c.want {
				t.Errorf("Marshal(float64(%v)) = %s, %v, want %s", c.in, got, err, c.want)
			}
		})
	}
}

func TestUnmarshalDuplicateKeyMatchesJQ(t *testing.T) {
	in := `{"a":1,"b":2,"a":3}`
	want := `{"a":3,"b":2}`
	v, err := Unmarshal([]byte(in))
	if err != nil {
		t.Fatalf("Unmarshal(%s): %v", in, err)
	}
	got, err := Marshal(v)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if string(got) != want {
		t.Errorf("Unmarshal(%s) roundtrip = %s, want %s", in, got, want)
	}
}

func TestUnmarshalPreservesKeyOrderRoundTrip(t *testing.T) {
	in := `{"z":1,"m":{"y":2,"x":[1,2,3]},"a":"hello","b":null,"c":true,"d":false,"e":-3.5}`
	v, err := Unmarshal([]byte(in))
	if err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	got, err := Marshal(v)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if string(got) != in {
		t.Errorf("Unmarshal->Marshal roundtrip = %s, want %s", got, in)
	}

	obj, ok := v.(*Object)
	if !ok {
		t.Fatalf("top-level value is %T, want *Object", v)
	}
	wantKeys := []string{"z", "m", "a", "b", "c", "d", "e"}
	gotKeys := obj.Keys()
	if len(gotKeys) != len(wantKeys) {
		t.Fatalf("Keys() = %v, want %v", gotKeys, wantKeys)
	}
	for i, k := range wantKeys {
		if gotKeys[i] != k {
			t.Errorf("Keys()[%d] = %q, want %q", i, gotKeys[i], k)
		}
	}
}

func TestObjectAssignmentSemantics(t *testing.T) {
	obj := NewObject()
	obj.Set("a", int64(1))
	obj.Set("b", int64(2))
	obj.Set("c", int64(3))

	obj.Set("b", int64(99))
	want := `{"a":1,"b":99,"c":3}`
	if got, err := Marshal(obj); err != nil || string(got) != want {
		t.Errorf("after Set(existing key) = %s, %v, want %s", got, err, want)
	}

	obj.Set("d", int64(4))
	want = `{"a":1,"b":99,"c":3,"d":4}`
	if got, err := Marshal(obj); err != nil || string(got) != want {
		t.Errorf("after Set(new key) = %s, %v, want %s", got, err, want)
	}
}

func TestObjectDeleteAndGet(t *testing.T) {
	obj := NewObject()
	obj.Set("a", int64(1))
	obj.Set("b", int64(2))
	obj.Set("c", int64(3))
	obj.Delete("b")

	want := `{"a":1,"c":3}`
	if got, err := Marshal(obj); err != nil || string(got) != want {
		t.Errorf("after Delete = %s, %v, want %s", got, err, want)
	}
	if _, ok := obj.Get("b"); ok {
		t.Errorf("Get(deleted key) reported ok=true")
	}
	if v, ok := obj.Get("a"); !ok || v.(int64) != 1 {
		t.Errorf("Get(a) = %v, %v, want 1, true", v, ok)
	}
	if obj.Len() != 2 {
		t.Errorf("Len() = %d, want 2", obj.Len())
	}
}

// WHY: fingerprint bytes are captured from the pinned jq via
// `jq -cnS --arg revision ... --argjson entries ... '{revision,entries}'`.
func TestLifecycleSnapshotFingerprint(t *testing.T) {
	revision := "abcdef1234567890"
	entries := NewObject()
	entries.Set("src/main.go", "blob:abc123")
	entries.Set("path with spaces/x.py", "file:deadbeef")
	entries.Set(`quote"path`, "blob:1")
	entries.Set(`back\slash`, "blob:2")
	entries.Set("日本語/ファイル.txt", "blob:3")

	fp := NewObject()
	fp.Set("revision", revision)
	fp.Set("entries", entries)

	wantSortedBytes := `{"entries":{"back\\slash":"blob:2","path with spaces/x.py":"file:deadbeef","quote\"path":"blob:1","src/main.go":"blob:abc123","日本語/ファイル.txt":"blob:3"},"revision":"abcdef1234567890"}`
	gotSortedBytes, err := MarshalSorted(fp)
	if err != nil {
		t.Fatalf("MarshalSorted: %v", err)
	}
	if string(gotSortedBytes) != wantSortedBytes {
		t.Fatalf("MarshalSorted(fingerprint doc) =\n%s\nwant\n%s", gotSortedBytes, wantSortedBytes)
	}

	sum := sha256.Sum256(gotSortedBytes)
	fingerprint := hex.EncodeToString(sum[:])
	wantFingerprint := "40dfcb172b30475b23c6828c34b80d7ea4636e778765adb7db40e0bafa27c7b8"
	if fingerprint != wantFingerprint {
		t.Errorf("fingerprint = %s, want %s", fingerprint, wantFingerprint)
	}

	doc := NewObject()
	doc.Set("revision", revision)
	doc.Set("entries", entries)
	doc.Set("fingerprint", fingerprint)
	doc.Set("error", nil)

	wantDoc := `{"revision":"abcdef1234567890","entries":{"src/main.go":"blob:abc123","path with spaces/x.py":"file:deadbeef","quote\"path":"blob:1","back\\slash":"blob:2","日本語/ファイル.txt":"blob:3"},"fingerprint":"40dfcb172b30475b23c6828c34b80d7ea4636e778765adb7db40e0bafa27c7b8","error":null}`
	gotDoc, err := Marshal(doc)
	if err != nil {
		t.Fatalf("Marshal(snapshot doc): %v", err)
	}
	if string(gotDoc) != wantDoc {
		t.Fatalf("Marshal(snapshot doc) =\n%s\nwant\n%s", gotDoc, wantDoc)
	}

	roundTripped, err := Unmarshal(gotDoc)
	if err != nil {
		t.Fatalf("Unmarshal(snapshot doc): %v", err)
	}
	reencoded, err := Marshal(roundTripped)
	if err != nil {
		t.Fatalf("Marshal(roundtripped snapshot doc): %v", err)
	}
	if !bytes.Equal(reencoded, gotDoc) {
		t.Errorf("Unmarshal->Marshal roundtrip =\n%s\nwant\n%s", reencoded, gotDoc)
	}
}

func TestMarshalUnsupportedType(t *testing.T) {
	if _, err := Marshal(struct{}{}); err == nil {
		t.Error("Marshal(unsupported type) returned nil error, want error")
	}
}

func TestUnmarshalRejectsMalformedJSON(t *testing.T) {
	cases := []string{
		`{"a":}`,
		`{"a":1,}`,
		`[1,2,]`,
		`{a:1}`,
		`"unterminated`,
		`"raw` + "\n" + `control"`,
		`01`,
		`.5`,
		`{"a":1} trailing`,
	}
	for _, in := range cases {
		if _, err := Unmarshal([]byte(in)); err == nil {
			t.Errorf("Unmarshal(%q) returned nil error, want error", in)
		}
	}
}

func TestUnmarshalSurrogatePairs(t *testing.T) {
	v, err := Unmarshal([]byte(`"\ud83c\udf89"`))
	if err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	want := "🎉"
	if v.(string) != want {
		t.Errorf("Unmarshal(surrogate pair) = %q, want %q", v, want)
	}

	if _, err := Unmarshal([]byte(`"\ud800"`)); err == nil {
		t.Error("Unmarshal(lone high surrogate) returned nil error, want error")
	}
	if _, err := Unmarshal([]byte(`"\ud800x"`)); err == nil {
		t.Error("Unmarshal(high surrogate + non-surrogate) returned nil error, want error")
	}

	v2, err := Unmarshal([]byte(`"\udc00"`))
	if err != nil {
		t.Fatalf("Unmarshal(lone low surrogate): %v", err)
	}
	if v2.(string) != "\ufffd" {
		t.Errorf("Unmarshal(lone low surrogate) = %q, want U+FFFD", v2)
	}
}
