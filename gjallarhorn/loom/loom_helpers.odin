package loom

import "core:strings"

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

// string_literal pulls the first quoted string out of `s` (e.g. the "base.html"
// in `extends "base.html"`), reusing the expression lexer so quoting and escapes
// behave the same everywhere. Returns "" if there is no string literal.
//
// The result is cloned into context.allocator, NOT left pointing at lex_expr's
// scratch: callers retain it (the parser stores include/extends names in the
// node tree, which for a cached template lives on the heap). lex_expr builds a
// .Str token's text in the temp allocator, so returning it raw would leave a
// cached node pointing into a per-request arena that is freed when the parsing
// worker exits — a use-after-free on the next render (see the Loom cache).
string_literal :: proc(s: string) -> string {
	for tk in lex_expr(s, context.temp_allocator) {
		if tk.kind == .Str {
			return strings.clone(tk.text, context.allocator)
		}
	}
	return ""
}

slice_contains :: proc(arr: []string, v: string) -> bool {
	for x in arr {
		if x == v {
			return true
		}
	}
	return false
}

is_space :: proc(c: u8) -> bool {return c == ' ' || c == '\t' || c == '\n' || c == '\r'}
is_alpha :: proc(c: u8) -> bool {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')}
is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}
is_alnum :: proc(c: u8) -> bool {return is_alpha(c) || is_digit(c)}
