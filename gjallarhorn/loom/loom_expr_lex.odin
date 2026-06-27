package loom

import "core:strings"

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
