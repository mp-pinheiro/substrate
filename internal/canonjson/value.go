// WHY: jq -c never HTML-escapes or sorts keys; encoding/json always does
// both, so it cannot produce jq-identical bytes.
package canonjson

type Value any

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
