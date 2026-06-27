package loom

import "core:strings"
import "core:strconv"

// ---------------------------------------------------------------------------
// Expression evaluation
//
// A tiny recursive-descent interpreter over expression tokens. Precedence,
// loosest first:  or  <  and  <  not  <  comparison  <  filter  <  primary.
// Every level returns an Eval so the `safe` decision survives to the output.
// ---------------------------------------------------------------------------

// Eval — a value plus whether it is cleared for verbatim (unescaped) output.
Eval :: struct {
	val:  Value,
	safe: bool,
}

Etok_Kind :: enum {
	Ident,
	Number,
	Str,
	Op, // == != < > <= >=
	Dot,
	Pipe,
	LParen,
	RParen,
	Comma,
	End,
}

Etok :: struct {
	kind: Etok_Kind,
	text: string,
}

Interp :: struct {
	toks: []Etok,
	pos:  int,
	ctx:  ^Warp,
}

eval :: proc(src: string, ctx: ^Warp) -> Eval {
	toks := lex_expr(src, context.temp_allocator)
	it := Interp{toks = toks[:], pos = 0, ctx = ctx}
	return ev_or(&it)
}

peek :: proc(it: ^Interp) -> Etok {
	if it.pos < len(it.toks) {
		return it.toks[it.pos]
	}
	return Etok{kind = .End}
}

adv :: proc(it: ^Interp) -> Etok {
	t := peek(it)
	it.pos += 1
	return t
}

ev_or :: proc(it: ^Interp) -> Eval {
	l := ev_and(it)
	for {
		t := peek(it)
		if t.kind == .Ident && t.text == "or" {
			adv(it)
			r := ev_and(it)
			l = Eval{truthy(l.val) || truthy(r.val), false}
		} else {
			break
		}
	}
	return l
}

ev_and :: proc(it: ^Interp) -> Eval {
	l := ev_not(it)
	for {
		t := peek(it)
		if t.kind == .Ident && t.text == "and" {
			adv(it)
			r := ev_not(it)
			l = Eval{truthy(l.val) && truthy(r.val), false}
		} else {
			break
		}
	}
	return l
}

ev_not :: proc(it: ^Interp) -> Eval {
	t := peek(it)
	if t.kind == .Ident && t.text == "not" {
		adv(it)
		return Eval{!truthy(ev_not(it).val), false}
	}
	return ev_cmp(it)
}

ev_cmp :: proc(it: ^Interp) -> Eval {
	l := ev_filter(it)
	t := peek(it)
	if t.kind == .Op {
		adv(it)
		r := ev_filter(it)
		return Eval{do_compare(l.val, t.text, r.val), false}
	}
	return l
}

ev_filter :: proc(it: ^Interp) -> Eval {
	e := ev_primary(it)
	for {
		if peek(it).kind != .Pipe {
			break
		}
		adv(it)
		name := peek(it)
		if name.kind != .Ident {
			break
		}
		adv(it)
		arg: Value = nil
		has_arg := false
		if peek(it).kind == .LParen {
			adv(it)
			arg = ev_or(it).val
			has_arg = true
			if peek(it).kind == .RParen {
				adv(it)
			}
		}
		e = apply_filter(name.text, e, arg, has_arg)
	}
	return e
}

ev_primary :: proc(it: ^Interp) -> Eval {
	t := peek(it)
	switch t.kind {
	case .Number:
		adv(it)
		if strings.contains(t.text, ".") {
			f, _ := strconv.parse_f64(t.text)
			return Eval{f, false}
		}
		n, _ := strconv.parse_int(t.text)
		return Eval{n, false}
	case .Str:
		adv(it)
		return Eval{t.text, false}
	case .LParen:
		adv(it)
		e := ev_or(it)
		if peek(it).kind == .RParen {
			adv(it)
		}
		return e
	case .Ident:
		adv(it)
		switch t.text {
		case "true":
			return Eval{true, false}
		case "false":
			return Eval{false, false}
		case "nil", "none", "None":
			return Eval{nil, false}
		}
		parts := make([dynamic]string, context.temp_allocator)
		append(&parts, t.text)
		for {
			if peek(it).kind != .Dot {
				break
			}
			adv(it)
			nx := peek(it)
			if nx.kind != .Ident {
				break
			}
			adv(it)
			append(&parts, nx.text)
		}
		return Eval{lookup_path(it.ctx, parts[:]), false}
	case .Op, .Dot, .Pipe, .RParen, .Comma, .End:
		adv(it)
		return Eval{nil, false}
	}
	return Eval{nil, false}
}

lookup_path :: proc(ctx: ^Warp, parts: []string) -> Value {
	cur, ok := (ctx^)[parts[0]]
	if !ok {
		return nil
	}
	for i in 1 ..< len(parts) {
		m, mok := cur.(map[string]Value)
		if !mok {
			return nil
		}
		cur, ok = m[parts[i]]
		if !ok {
			return nil
		}
	}
	return cur
}
