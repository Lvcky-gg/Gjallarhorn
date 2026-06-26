package gjallarhorn

// body.odin — typed request-body decoders. Sits on top of the raw body that
// server.odin assembles (b.body / b.body_text, see GH-002).

import "core:encoding/json"
import "core:strings"

// bind_json unmarshals the request body into ptr via core:encoding/json. On a
// malformed (or empty) body it writes a 400 and returns false, so handlers can
// simply `if !bind_json(b, &x) { return }`.
bind_json :: proc(b: ^Bifrost, ptr: ^$T) -> bool {
	if err := json.unmarshal(b.body, ptr, allocator = context.temp_allocator); err != nil {
		text(b, 400, "400 invalid JSON body")
		return false
	}
	return true
}

// form parses an application/x-www-form-urlencoded body into a map. Keys and
// values are percent- and '+'-decoded. Lenient by design: blank pairs are
// skipped and a malformed percent-escape is left literal rather than failing.
form :: proc(b: ^Bifrost, allocator := context.temp_allocator) -> map[string]string {
	out := make(map[string]string, allocator)
	for pair in strings.split(b.body_text, "&", allocator) {
		if pair == "" {
			continue
		}
		key, val := pair, ""
		if eq := strings.index(pair, "="); eq >= 0 {
			key, val = pair[:eq], pair[eq + 1:]
		}
		out[url_decode(key, allocator)] = url_decode(val, allocator)
	}
	return out
}

// url_decode reverses x-www-form-urlencoded escaping: '+' -> space and %XX ->
// the byte. A truncated or non-hex escape is preserved literally.
url_decode :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '%') < 0 && strings.index_byte(s, '+') < 0 {
		return s
	}
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); {
		switch s[i] {
		case '+':
			strings.write_byte(&sb, ' ')
			i += 1
		case '%':
			hi, lo := -1, -1
			if i + 2 < len(s) {
				hi, lo = hex_val(s[i + 1]), hex_val(s[i + 2])
			}
			if hi >= 0 && lo >= 0 {
				strings.write_byte(&sb, u8(hi * 16 + lo))
				i += 3
			} else {
				strings.write_byte(&sb, '%')
				i += 1
			}
		case:
			strings.write_byte(&sb, s[i])
			i += 1
		}
	}
	return strings.to_string(sb)
}

hex_val :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a' + 10)
	case 'A' ..= 'F':
		return int(c - 'A' + 10)
	}
	return -1
}
