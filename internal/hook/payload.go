package hook

import (
	"fmt"
	"strings"

	"github.com/mp-pinheiro/substrate/internal/canonjson"
	"github.com/mp-pinheiro/substrate/internal/xshell"
)

// A non-null non-object index errors and jq's `//` does not catch it — verified against the pinned jq.
func jqAlt(v canonjson.Value, paths ...string) (result string, failed bool) {
	for _, path := range paths {
		cur := v
		errored := false
		for _, seg := range strings.Split(path, ".") {
			if cur == nil {
				continue
			}
			obj, ok := cur.(*canonjson.Object)
			if !ok {
				errored = true
				break
			}
			next, present := obj.Get(seg)
			if !present {
				cur = nil
				continue
			}
			cur = next
		}
		if errored {
			return "", true
		}
		if cur == nil {
			continue
		}
		if b, ok := cur.(bool); ok && !b {
			continue
		}
		if s, ok := cur.(string); ok {
			return xshell.CleanCommandSubst(s), false
		}
		return xshell.CleanCommandSubst(fmt.Sprint(cur)), false
	}
	return "", false
}

func decodePayload(payload []byte) (canonjson.Value, bool) {
	v, err := canonjson.Unmarshal(payload)
	if err != nil {
		return nil, true
	}
	return v, false
}
