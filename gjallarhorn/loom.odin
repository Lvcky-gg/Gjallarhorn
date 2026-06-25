package gjallarhorn

// loom.odin — Loom, the templating engine. In the myths the Norns sit at the
// well of Urðr and weave the threads of fate; so here a template is the warp
// already strung on the loom, and `weave` runs the weft of your data through
// it to produce the finished cloth (HTML).
//
// The dialect is Jinja's, pared to its load-bearing parts:
//
//   {{ expr }}              output an expression (HTML-escaped by default)
//   {{ expr | filter }}     run it through a filter pipeline (upper, default…)
//   {% if c %}…{% elif %}…{% else %}…{% endif %}   branch
//   {% for x in xs %}…{% else %}…{% endfor %}      iterate (empty -> else)
//   {# … #}                comment, dropped
//
// Inside a `for`, a `loop` binding carries index / index0 / first / last /
// length, as in Jinja.
//
// The security checkpoint for this feature is XSS: output is HTML-escaped
// unless the expression's filter pipeline ends in `| safe` (or `| escape`,
// which escapes then marks safe). Safety rides alongside the value as it is
// evaluated (see Eval), so it is decided per output, not globally.
//
// Phase note, matching the rest of gjallarhorn's incremental honesty: this is
// the expression/statement core. Template inheritance ({% extends %} /
// {% block %}), includes, macros, and whitespace-control ({%- -%}) are the
// next phase. Expressions are re-parsed each render — fine here; a compiled
// node cache is the optimisation seam.

import "core:os"
import "core:fmt"
import "core:strings"
import "core:strconv"

// ---------------------------------------------------------------------------
// The data a template can see
// ---------------------------------------------------------------------------

// Value — the dynamic cell a template renders or branches on. Odin has no
// `any`-ish runtime value the way Python does, so Loom carries its own. The
// nil (no-variant) state is the template's `none`.
Value :: union {
	string,
	int,
	f64,
	bool,
	[]Value,
	map[string]Value,
}

// Warp — the named threads strung on the loom before weaving: the context a
// template looks names up in. Plain alias (not distinct) so a nested map slots
// straight into a `Value` for sub-objects. Build one with `warp`.
Warp :: map[string]Value

// Binding — one key/value thread, the argument shape of `warp`.
Binding :: struct {
	key: string,
	val: Value,
}

Loom_Error :: enum {
	None,
	Unexpected_End, // a block tag left open ({% if %} with no {% endif %})
	Unknown_Tag,    // a {% … %} whose keyword Loom doesn't know
	Bad_Syntax,     // e.g. {% for %} without "x in xs"
}

// ---------------------------------------------------------------------------
// Public verbs
// ---------------------------------------------------------------------------

// warp: thread a context from key/value pairs, e.g.
//   gh.warp({"title", "Gjallarhorn"}, {"user", gh.warp({"name", "Heimdallr"})})
// A constructor (rather than a raw `Warp{…}` literal) so callers need neither
// Odin's dynamic-literals feature flag nor explicit Value conversions.
warp :: proc(bindings: ..Binding, allocator := context.allocator) -> Warp {
	m := make(Warp, len(bindings), allocator)
	for b in bindings {
		m[b.key] = b.val
	}
	return m
}

// weave: run `ctx` through template source `src`, returning the woven text in
// `allocator`. The string-in / string-out core; `render` layers file loading
// and the HTTP response on top.
weave :: proc(src: string, ctx: Warp, allocator := context.allocator) -> (string, Loom_Error) {
	toks := lex(src, context.temp_allocator)
	p := Parser{toks = toks[:], pos = 0}
	nodes, _, err := parse_block(&p, nil)
	if err != .None {
		return "", err
	}

	local := ctx // a header copy we may add scratch bindings (loop, loop vars) to
	sb := strings.builder_make(allocator)
	if rerr := render_nodes(&sb, nodes, &local); rerr != .None {
		return strings.to_string(sb), rerr
	}
	return strings.to_string(sb), .None
}

// html (Bifrost helper): send `body` as text/html, the sibling of `text` and
// `json` over in bifrost.odin.
html :: proc(b: ^Bifrost, status: int, body: string) {
	write_response(b, status, "text/html; charset=utf-8", body)
}

// render (Bifrost helper): load a template file, weave `ctx` through it, and
// send the result as HTML. `path` is supplied by the handler, not the request,
// so this carries no traversal checkpoint of its own — see hail/serve_static
// (static.odin) for the user-path case.
render :: proc(b: ^Bifrost, path: string, ctx: Warp) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		text(b, 500, "template not found")
		return
	}
	out, werr := weave(string(data), ctx, context.temp_allocator)
	if werr != .None {
		text(b, 500, "template error")
		return
	}
	html(b, 200, out)
}

// ---------------------------------------------------------------------------
// Tokenising the template into text / output / tag tokens
// ---------------------------------------------------------------------------

Token_Kind :: enum {
	Text,   // literal run between tags
	Output, // inside {{ … }}
	Tag,    // inside {% … %}
}

Token :: struct {
	kind:  Token_Kind,
	value: string, // raw text, or the trimmed inner of an output/tag
}

lex :: proc(src: string, allocator := context.allocator) -> [dynamic]Token {
	toks := make([dynamic]Token, allocator)
	i := 0
	start := 0
	for i < len(src) {
		if src[i] == '{' && i + 1 < len(src) {
			open, close: string
			is_comment := false
			switch src[i + 1] {
			case '{':
				open, close = "{{", "}}"
			case '%':
				open, close = "{%", "%}"
			case '#':
				open, close, is_comment = "{#", "#}", true
			case:
				i += 1
				continue
			}

			rest := src[i + 2:]
			ci := strings.index(rest, close)
			if ci < 0 {
				// No closing delimiter anywhere; treat the brace as literal.
				i += 1
				continue
			}

			if i > start {
				append(&toks, Token{kind = .Text, value = src[start:i]})
			}
			if !is_comment {
				kind := open == "{{" ? Token_Kind.Output : Token_Kind.Tag
				append(&toks, Token{kind = kind, value = strings.trim_space(rest[:ci])})
			}
			i = i + 2 + ci + len(close)
			start = i
		} else {
			i += 1
		}
	}
	if start < len(src) {
		append(&toks, Token{kind = .Text, value = src[start:]})
	}
	return toks
}

// ---------------------------------------------------------------------------
// Parsing tokens into a node tree
// ---------------------------------------------------------------------------

Node_Kind :: enum {
	Text,   // literal
	Output, // {{ expr }} — expr in `text`
	If,      // {% if expr %} — expr in `text`; body / alt branches
	For,     // {% for ivar in iter %} — body, alt(empty case)
}

Node :: struct {
	kind: Node_Kind,
	text: string, // Text literal | Output expr | If condition
	ivar: string, // For: loop variable
	iter: string, // For: iterable expression
	body: [dynamic]Node,
	alt:  [dynamic]Node,
}

Parser :: struct {
	toks: []Token,
	pos:  int,
}

// parse_block consumes nodes until it meets a tag whose keyword is in `stops`
// (left unconsumed, returned in `term`) or the end of input. With `stops` nil
// it reads the whole template.
parse_block :: proc(p: ^Parser, stops: []string) -> (nodes: [dynamic]Node, term: string, err: Loom_Error) {
	nodes = make([dynamic]Node, context.temp_allocator)
	for p.pos < len(p.toks) {
		t := p.toks[p.pos]
		switch t.kind {
		case .Text:
			append(&nodes, Node{kind = .Text, text = t.value})
			p.pos += 1
		case .Output:
			append(&nodes, Node{kind = .Output, text = t.value})
			p.pos += 1
		case .Tag:
			kw := first_word(t.value)
			if slice_contains(stops, kw) {
				return nodes, kw, .None
			}
			switch kw {
			case "if":
				n, e := parse_if(p)
				if e != .None {
					return nodes, "", e
				}
				append(&nodes, n)
			case "for":
				n, e := parse_for(p)
				if e != .None {
					return nodes, "", e
				}
				append(&nodes, n)
			case:
				return nodes, "", .Unknown_Tag
			}
		}
	}
	if len(stops) > 0 {
		return nodes, "", .Unexpected_End
	}
	return nodes, "", .None
}

parse_if :: proc(p: ^Parser) -> (Node, Loom_Error) {
	tag := p.toks[p.pos]
	p.pos += 1
	node := Node{kind = .If, text = after_keyword(tag.value, "if")}

	body, term, e := parse_block(p, {"elif", "else", "endif"})
	if e != .None {
		return {}, e
	}
	node.body = body

	alt, e2 := parse_if_tail(p, term)
	if e2 != .None {
		return {}, e2
	}
	node.alt = alt
	return node, .None
}

// parse_if_tail consumes the terminator parse_if stopped on and builds the
// else branch. An `elif` is desugared into a nested If living in `alt`, so the
// node model needs only condition / body / alt.
parse_if_tail :: proc(p: ^Parser, term: string) -> ([dynamic]Node, Loom_Error) {
	switch term {
	case "endif":
		p.pos += 1
		return nil, .None
	case "else":
		p.pos += 1
		alt, _, e := parse_block(p, {"endif"})
		if e != .None {
			return nil, e
		}
		p.pos += 1 // consume endif
		return alt, .None
	case "elif":
		tag := p.toks[p.pos]
		p.pos += 1
		inner := Node{kind = .If, text = after_keyword(tag.value, "elif")}
		body, t2, e := parse_block(p, {"elif", "else", "endif"})
		if e != .None {
			return nil, e
		}
		inner.body = body
		tail, e2 := parse_if_tail(p, t2)
		if e2 != .None {
			return nil, e2
		}
		inner.alt = tail
		arr := make([dynamic]Node, context.temp_allocator)
		append(&arr, inner)
		return arr, .None
	}
	return nil, .Bad_Syntax
}

parse_for :: proc(p: ^Parser) -> (Node, Loom_Error) {
	tag := p.toks[p.pos]
	p.pos += 1
	spec := after_keyword(tag.value, "for")
	idx := strings.index(spec, " in ")
	if idx < 0 {
		return {}, .Bad_Syntax
	}
	node := Node{
		kind = .For,
		ivar = strings.trim_space(spec[:idx]),
		iter = strings.trim_space(spec[idx + 4:]),
	}

	body, term, e := parse_block(p, {"else", "endfor"})
	if e != .None {
		return {}, e
	}
	node.body = body

	if term == "else" {
		p.pos += 1
		alt, _, e2 := parse_block(p, {"endfor"})
		if e2 != .None {
			return {}, e2
		}
		node.alt = alt
	}
	p.pos += 1 // consume endfor
	return node, .None
}

// ---------------------------------------------------------------------------
// Rendering the node tree
// ---------------------------------------------------------------------------

render_nodes :: proc(sb: ^strings.Builder, nodes: [dynamic]Node, ctx: ^Warp) -> Loom_Error {
	for n in nodes {
		switch n.kind {
		case .Text:
			strings.write_string(sb, n.text)
		case .Output:
			render_output(sb, n.text, ctx)
		case .If:
			branch := truthy(eval(n.text, ctx).val) ? n.body : n.alt
			if e := render_nodes(sb, branch, ctx); e != .None {
				return e
			}
		case .For:
			if e := render_for(sb, n, ctx); e != .None {
				return e
			}
		}
	}
	return .None
}

// render_output is the escape checkpoint: a value whose pipeline ended in
// `safe`/`escape` is written verbatim, anything else is HTML-escaped.
render_output :: proc(sb: ^strings.Builder, expr: string, ctx: ^Warp) {
	e := eval(expr, ctx)
	s := to_text(e.val)
	if e.safe {
		strings.write_string(sb, s)
	} else {
		strings.write_string(sb, html_escape(s, context.temp_allocator))
	}
}

render_for :: proc(sb: ^strings.Builder, n: Node, ctx: ^Warp) -> Loom_Error {
	v := eval(n.iter, ctx).val
	arr, ok := v.([]Value)
	if !ok || len(arr) == 0 {
		return render_nodes(sb, n.alt, ctx) // empty -> the {% else %} body
	}

	// Shadow the loop variable and `loop`, restoring whatever they hid after.
	old_item, had_item := (ctx^)[n.ivar]
	old_loop, had_loop := (ctx^)["loop"]
	for item, i in arr {
		(ctx^)[n.ivar] = item

		lm := make(map[string]Value, context.temp_allocator)
		lm["index0"] = i
		lm["index"] = i + 1
		lm["first"] = i == 0
		lm["last"] = i == len(arr) - 1
		lm["length"] = len(arr)
		(ctx^)["loop"] = lm

		if e := render_nodes(sb, n.body, ctx); e != .None {
			return e
		}
	}

	if had_item {(ctx^)[n.ivar] = old_item} else {delete_key(ctx, n.ivar)}
	if had_loop {(ctx^)["loop"] = old_loop} else {delete_key(ctx, "loop")}
	return .None
}

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

// ---------------------------------------------------------------------------
// Expression tokeniser
// ---------------------------------------------------------------------------

lex_expr :: proc(s: string, allocator := context.allocator) -> [dynamic]Etok {
	toks := make([dynamic]Etok, allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i += 1
		case is_alpha(c) || c == '_':
			j := i
			for j < len(s) && (is_alnum(s[j]) || s[j] == '_') {
				j += 1
			}
			append(&toks, Etok{.Ident, s[i:j]})
			i = j
		case is_digit(c):
			j := i
			for j < len(s) && is_digit(s[j]) {
				j += 1
			}
			if j + 1 < len(s) && s[j] == '.' && is_digit(s[j + 1]) {
				j += 1
				for j < len(s) && is_digit(s[j]) {
					j += 1
				}
			}
			append(&toks, Etok{.Number, s[i:j]})
			i = j
		case c == '"' || c == '\'':
			q := c
			j := i + 1
			lit := strings.builder_make(context.temp_allocator)
			for j < len(s) && s[j] != q {
				if s[j] == '\\' && j + 1 < len(s) {
					strings.write_byte(&lit, s[j + 1])
					j += 2
				} else {
					strings.write_byte(&lit, s[j])
					j += 1
				}
			}
			append(&toks, Etok{.Str, strings.to_string(lit)})
			i = j < len(s) ? j + 1 : j
		case c == '.':
			append(&toks, Etok{.Dot, "."}); i += 1
		case c == '|':
			append(&toks, Etok{.Pipe, "|"}); i += 1
		case c == '(':
			append(&toks, Etok{.LParen, "("}); i += 1
		case c == ')':
			append(&toks, Etok{.RParen, ")"}); i += 1
		case c == ',':
			append(&toks, Etok{.Comma, ","}); i += 1
		case c == '=' || c == '!' || c == '<' || c == '>':
			if i + 1 < len(s) && s[i + 1] == '=' {
				append(&toks, Etok{.Op, s[i:i + 2]}); i += 2
			} else {
				append(&toks, Etok{.Op, s[i:i + 1]}); i += 1
			}
		case:
			i += 1
		}
	}
	return toks
}

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

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

html_escape :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&':
			strings.write_string(&sb, "&amp;")
		case '<':
			strings.write_string(&sb, "&lt;")
		case '>':
			strings.write_string(&sb, "&gt;")
		case '"':
			strings.write_string(&sb, "&#34;")
		case '\'':
			strings.write_string(&sb, "&#39;")
		case:
			strings.write_byte(&sb, s[i])
		}
	}
	return strings.to_string(sb)
}

first_word :: proc(s: string) -> string {
	for i in 0 ..< len(s) {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			return s[:i]
		}
	}
	return s
}

// after_keyword returns the trimmed remainder of `s` past leading `kw`; the
// caller has already established `s` starts with `kw`.
after_keyword :: proc(s, kw: string) -> string {
	return strings.trim_space(s[len(kw):])
}

slice_contains :: proc(arr: []string, v: string) -> bool {
	for x in arr {
		if x == v {
			return true
		}
	}
	return false
}

is_alpha :: proc(c: u8) -> bool {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')}
is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}
is_alnum :: proc(c: u8) -> bool {return is_alpha(c) || is_digit(c)}
