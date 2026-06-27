package loom

// loom_reflect.odin — bridge from typed Odin values into Loom's Value/Warp world
// (GH-043). The model layer (mimir) hands back plain structs; rather than make
// callers hand-build a Warp per row, warp_of reflects a struct straight into one,
// so a scanned ORM row flows into a template untouched:
//
//   row := mimir.recall(...)            // a User struct
//   render(b, "user.html", loom.warp_of(row))   // {{ name }}, {{ admin }} …
//
// Keys are the struct's field names. A `loom:"alias"` tag renames the key for
// templates; `loom:"-"` drops the field. Nested structs become nested Warps and
// slices/arrays become []Value, so dotted lookups and {% for %} just work.

import "base:runtime"
import "core:reflect"

// value_of converts any Odin value into a Loom Value by reflection. Scalars map
// to the matching variant; structs recurse into Warps; slices/arrays into
// []Value; a pointer is followed (nil -> nil). Kinds Loom has no home for
// collapse to nil rather than erroring.
value_of :: proc(v: any, allocator := context.allocator) -> Value {
	if v == nil || v.data == nil {
		return nil
	}
	core := reflect.type_info_core(type_info_of(v.id))

	#partial switch info in core.variant {
	case runtime.Type_Info_String:
		s, _ := reflect.as_string(v)
		return s
	case runtime.Type_Info_Boolean:
		b, _ := reflect.as_bool(v)
		return b
	case runtime.Type_Info_Integer, runtime.Type_Info_Enum:
		n, _ := reflect.as_int(v)
		return n
	case runtime.Type_Info_Float:
		f, _ := reflect.as_f64(v)
		return f
	case runtime.Type_Info_Struct:
		return warp_of(v, allocator)
	case runtime.Type_Info_Pointer:
		d := reflect.deref(v)
		if d.data == nil {
			return nil
		}
		return value_of(d, allocator)
	case runtime.Type_Info_Slice, runtime.Type_Info_Array, runtime.Type_Info_Dynamic_Array:
		n := reflect.length(v)
		out := make([]Value, n, allocator)
		for i in 0 ..< n {
			out[i] = value_of(reflect.index(v, i), allocator)
		}
		return out
	}
	return nil
}

// warp_of reflects a struct value into a Warp keyed by field name (overridable
// with a `loom:"alias"` tag; `loom:"-"` skips). A pointer to a struct is
// followed; anything that isn't a struct yields an empty Warp.
warp_of :: proc(v: any, allocator := context.allocator) -> Warp {
	m := make(Warp, 0, allocator)

	val := v
	if _, is_ptr := reflect.type_info_core(type_info_of(val.id)).variant.(runtime.Type_Info_Pointer);
	   is_ptr {
		val = reflect.deref(val)
		if val.data == nil {
			return m
		}
	}

	core := reflect.type_info_core(type_info_of(val.id))
	if _, ok := core.variant.(runtime.Type_Info_Struct); !ok {
		return m
	}

	for f in reflect.struct_fields_zipped(val.id) {
		tag := reflect.struct_tag_get(f.tag, "loom")
		if tag == "-" {
			continue
		}
		key := tag != "" ? tag : f.name
		m[key] = value_of(reflect.struct_field_value(val, f), allocator)
	}
	return m
}
