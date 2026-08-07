// Package jqx holds the nil-receiver-safe canonjson.Object field accessors
// jq-semantics callers need, promoted out of internal/lifecycle so a second
// package does not duplicate them (internal/lifecycle keeps its own copies).
package jqx

import "github.com/mp-pinheiro/substrate/internal/canonjson"

func ObjString(o *canonjson.Object, key string) string {
	if o == nil {
		return ""
	}
	v, ok := o.Get(key)
	if !ok {
		return ""
	}
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return s
}

func ObjBool(o *canonjson.Object, key string, def bool) bool {
	if o == nil {
		return def
	}
	v, ok := o.Get(key)
	if !ok {
		return def
	}
	b, ok := v.(bool)
	if !ok {
		return def
	}
	return b
}

func ObjIsString(o *canonjson.Object, key string) bool {
	if o == nil {
		return false
	}
	v, ok := o.Get(key)
	if !ok {
		return false
	}
	_, ok = v.(string)
	return ok
}

// ObjInt64Equals accepts both a Go-constructed int64 and a decoded
// canonjson.Number, since a value read back through Unmarshal is a Number.
func ObjInt64Equals(o *canonjson.Object, key string, target int64) bool {
	if o == nil {
		return false
	}
	v, ok := o.Get(key)
	if !ok {
		return false
	}
	switch n := v.(type) {
	case int64:
		return n == target
	case canonjson.Number:
		f, err := n.Float64()
		if err != nil {
			return false
		}
		return f == float64(target)
	default:
		return false
	}
}

func Nullable(s string) canonjson.Value {
	if s == "" {
		return nil
	}
	return s
}
