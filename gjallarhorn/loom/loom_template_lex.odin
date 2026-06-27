package loom

import "core:strings"

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

			// Whitespace control (Jinja-style): a `-` hugging either delimiter,
			// e.g. {%- … -%} or {{- … -}}, trims adjacent whitespace. The marker
			// is stripped from the inner before it reaches the parser.
			inner := rest[:ci]
			trim_left := len(inner) > 0 && inner[0] == '-'
			if trim_left {
				inner = inner[1:]
			}
			trim_right := len(inner) > 0 && inner[len(inner) - 1] == '-'
			if trim_right {
				inner = inner[:len(inner) - 1]
			}

			if i > start {
				text := src[start:i]
				if trim_left {
					text = strings.trim_right_space(text)
				}
				if len(text) > 0 {
					append(&toks, Token{kind = .Text, value = text})
				}
			}
			if !is_comment {
				kind := open == "{{" ? Token_Kind.Output : Token_Kind.Tag
				append(&toks, Token{kind = kind, value = strings.trim_space(inner)})
			}
			i = i + 2 + ci + len(close)
			start = i

			// A trailing `-` swallows the whitespace that follows the tag, so the
			// next text token never sees it.
			if trim_right {
				for start < len(src) && is_space(src[start]) {
					start += 1
				}
				i = start
			}
		} else {
			i += 1
		}
	}
	if start < len(src) {
		append(&toks, Token{kind = .Text, value = src[start:]})
	}
	return toks
}
