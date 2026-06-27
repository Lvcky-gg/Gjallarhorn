package loom

import "core:strings"

// ---------------------------------------------------------------------------
// Parsing tokens into a node tree
// ---------------------------------------------------------------------------

Node_Kind :: enum {
	Text,    // literal
	Output,  // {{ expr }} — expr in `text`
	If,      // {% if expr %} — expr in `text`; body / alt branches
	For,     // {% for ivar in iter %} — body, alt(empty case)
	Block,   // {% block name %}…{% endblock %} — name in `text`, default in body
	Extends, // {% extends "base" %} — base template name in `text`
	Include, // {% include "partial" %} — partial template name in `text`
}

Node :: struct {
	kind: Node_Kind,
	text: string, // Text literal | Output expr | If condition | Block/Extends name
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
	nodes = make([dynamic]Node, context.allocator)
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
			case "block":
				n, e := parse_block_node(p)
				if e != .None {
					return nodes, "", e
				}
				append(&nodes, n)
			case "extends":
				p.pos += 1
				name := string_literal(after_keyword(t.value, "extends"))
				if name == "" {
					return nodes, "", .Bad_Syntax
				}
				append(&nodes, Node{kind = .Extends, text = name})
			case "include":
				p.pos += 1
				name := string_literal(after_keyword(t.value, "include"))
				if name == "" {
					return nodes, "", .Bad_Syntax
				}
				append(&nodes, Node{kind = .Include, text = name})
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
		arr := make([dynamic]Node, context.allocator)
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

// parse_block_node reads {% block name %}…{% endblock %}. The name labels the
// block so a child template can override it; the body is the default content,
// rendered when no override exists. {% endblock %} may optionally repeat the
// name (Jinja-style) — we just consume the closing tag either way.
parse_block_node :: proc(p: ^Parser) -> (Node, Loom_Error) {
	tag := p.toks[p.pos]
	p.pos += 1
	name := first_word(after_keyword(tag.value, "block"))
	if name == "" {
		return {}, .Bad_Syntax
	}
	node := Node{kind = .Block, text = name}

	body, _, e := parse_block(p, {"endblock"})
	if e != .None {
		return {}, e
	}
	node.body = body
	p.pos += 1 // consume endblock
	return node, .None
}
