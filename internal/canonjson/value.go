// jq -c never HTML-escapes or sorts keys; encoding/json always does
// both, so it cannot produce jq-identical bytes.
package canonjson

import (
	"errors"
	"fmt"
	"strconv"
)

type Value any

// Number stores a parsed literal as jq 1.7.1's decNumber would, preserving
// precision a float64 round-trip would lose; Go-constructed numbers use dtoa instead.
type Number struct {
	neg      bool
	digits   string
	exponent int
}

// Float64 ignores strconv.ErrRange to mirror jq's own float coercion.
func (n Number) Float64() (float64, error) {
	f, err := strconv.ParseFloat(n.String(), 64)
	if err != nil && !errors.Is(err, strconv.ErrRange) {
		return 0, fmt.Errorf("canonjson: number %q: %w", n.String(), err)
	}
	return f, nil
}

// String renders the same bytes Marshal would emit for this number.
func (n Number) String() string {
	return string(appendNumber(nil, n))
}

type Object struct {
	keys   []string
	values map[string]Value
}

func NewObject() *Object {
	return &Object{values: make(map[string]Value)}
}

func (o *Object) Set(key string, v Value) *Object {
	if o.values == nil {
		o.values = make(map[string]Value)
	}
	if _, exists := o.values[key]; !exists {
		o.keys = append(o.keys, key)
	}
	o.values[key] = v
	return o
}

func (o *Object) Delete(key string) {
	if _, exists := o.values[key]; !exists {
		return
	}
	delete(o.values, key)
	for i, k := range o.keys {
		if k == key {
			o.keys = append(o.keys[:i], o.keys[i+1:]...)
			return
		}
	}
}

func (o *Object) Get(key string) (Value, bool) {
	v, ok := o.values[key]
	return v, ok
}

func (o *Object) Keys() []string {
	keys := make([]string, len(o.keys))
	copy(keys, o.keys)
	return keys
}

func (o *Object) Len() int {
	return len(o.keys)
}
