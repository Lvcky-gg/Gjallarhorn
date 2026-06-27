package loom

import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// Values: truthiness, comparison, text rendering, filters
// ---------------------------------------------------------------------------

truthy :: proc(v: Value) -> bool {
	switch x in v {
	case string:
		return len(x) > 0
	case int:
		return x != 0
	case f64:
		return x != 0
	case bool:
		return x
	case []Value:
		return len(x) > 0
	case map[string]Value:
		return len(x) > 0
	}
	return false // nil
}

as_f64 :: proc(v: Value) -> (f64, bool) {
	switch x in v {
	case int:
		return f64(x), true
	case f64:
		return x, true
	case string, bool, []Value, map[string]Value:
		return 0, false
	}
	return 0, false
}

values_equal :: proc(l, r: Value) -> bool {
	if l == nil && r == nil {
		return true
	}
	if lf, lok := as_f64(l); lok {
		if rf, rok := as_f64(r); rok {
			return lf == rf
		}
	}
	if lb, lok := l.(bool); lok {
		if rb, rok := r.(bool); rok {
			return lb == rb
		}
	}
	if ls, lok := l.(string); lok {
		if rs, rok := r.(string); rok {
			return ls == rs
		}
	}
	return false
}

do_compare :: proc(l: Value, op: string, r: Value) -> bool {
	switch op {
	case "==":
		return values_equal(l, r)
	case "!=":
		return !values_equal(l, r)
	}
	lf, lok := as_f64(l)
	rf, rok := as_f64(r)
	if lok && rok {
		switch op {
		case "<":
			return lf < rf
		case "<=":
			return lf <= rf
		case ">":
			return lf > rf
		case ">=":
			return lf >= rf
		}
	}
	c := strings.compare(to_text(l), to_text(r))
	switch op {
	case "<":
		return c < 0
	case "<=":
		return c <= 0
	case ">":
		return c > 0
	case ">=":
		return c >= 0
	}
	return false
}

to_text :: proc(v: Value) -> string {
	switch x in v {
	case string:
		return x
	case int:
		return fmt.tprintf("%d", x)
	case f64:
		return fmt.tprintf("%v", x)
	case bool:
		return x ? "true" : "false"
	case []Value:
		sb := strings.builder_make(context.temp_allocator)
		for e, i in x {
			if i > 0 {
				strings.write_string(&sb, ", ")
			}
			strings.write_string(&sb, to_text(e))
		}
		return strings.to_string(sb)
	case map[string]Value:
		return ""
	}
	return "" // nil
}

apply_filter :: proc(name: string, cur: Eval, arg: Value, has_arg: bool) -> Eval {
	v := cur.val
	switch name {
	case "upper":
		return Eval{strings.to_upper(to_text(v), context.temp_allocator), false}
	case "lower":
		return Eval{strings.to_lower(to_text(v), context.temp_allocator), false}
	case "trim":
		return Eval{strings.trim_space(to_text(v)), false}
	case "capitalize":
		s := to_text(v)
		if len(s) == 0 {
			return Eval{s, false}
		}
		head := strings.to_upper(s[:1], context.temp_allocator)
		return Eval{strings.concatenate({head, s[1:]}, context.temp_allocator), false}
	case "length", "count":
		switch x in v {
		case string:
			return Eval{len(x), false}
		case []Value:
			return Eval{len(x), false}
		case map[string]Value:
			return Eval{len(x), false}
		case int, f64, bool:
			return Eval{0, false}
		}
		return Eval{0, false}
	case "default":
		if has_arg && !truthy(v) {
			return Eval{arg, false}
		}
		return cur
	case "join":
		sep := has_arg ? to_text(arg) : ""
		arr, ok := v.([]Value)
		if !ok {
			return Eval{to_text(v), false}
		}
		sb := strings.builder_make(context.temp_allocator)
		for e, i in arr {
			if i > 0 {
				strings.write_string(&sb, sep)
			}
			strings.write_string(&sb, to_text(e))
		}
		return Eval{strings.to_string(sb), false}
	case "first":
		#partial switch x in v {
		case []Value:
			if len(x) > 0 {
				return Eval{x[0], false}
			}
		case string:
			if len(x) > 0 {
				return Eval{x[:1], false}
			}
		}
		return Eval{nil, false}
	case "last":
		#partial switch x in v {
		case []Value:
			if len(x) > 0 {
				return Eval{x[len(x) - 1], false}
			}
		case string:
			if len(x) > 0 {
				return Eval{x[len(x) - 1:], false}
			}
		}
		return Eval{nil, false}
	case "escape", "e":
		return Eval{html_escape(to_text(v), context.temp_allocator), true}
	case "safe":
		return Eval{v, true}
	}
	return cur // unknown filter: pass the value through unchanged
}
