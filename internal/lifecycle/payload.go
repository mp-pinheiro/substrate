package lifecycle

import (
	"bytes"
	"strconv"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
)

// sessionFromPayload mirrors `jq -r '.session_id // empty'`: empty stdin and
// JSON null both parse to "", and a non-object/non-null top level is malformed (jq's `.session_id` fails to index a scalar).
func sessionFromPayload(payload []byte) (session string, malformed bool) {
	trimmed := bytes.TrimSpace(payload)
	if len(trimmed) == 0 {
		return "", false
	}
	val, err := canonjson.Unmarshal(payload)
	if err != nil {
		return "", true
	}
	switch v := val.(type) {
	case nil:
		return "", false
	case *canonjson.Object:
		return jqRawSessionID(v), false
	default:
		return "", true
	}
}

func jqRawSessionID(obj *canonjson.Object) string {
	v, ok := obj.Get("session_id")
	if !ok {
		return ""
	}
	switch t := v.(type) {
	case nil:
		return ""
	case bool:
		if !t {
			return ""
		}
		return "true"
	case string:
		return t
	case int64:
		return strconv.FormatInt(t, 10)
	default:
		b, err := canonjson.Marshal(v)
		if err != nil {
			return ""
		}
		return string(b)
	}
}
