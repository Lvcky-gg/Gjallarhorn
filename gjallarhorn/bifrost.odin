package gjallarhorn

// bifrost.odin — the request/response object that crosses the bridge, plus the
// helpers a handler calls on it. Named off "Context" so it never shadows
// Odin's implicit `context`.

import "core:net"
import "core:strconv"
import "core:encoding/json"

Bifrost :: struct {
	method:    Method,
	path:      string,
	params:    map[string]string,
	headers:   map[string]string, // response headers
	client:    net.TCP_Socket,
	written:   bool,

	// Chain state, driven by `next`. Underscored: not for handler use.
	_app:      ^App,
	_mw_index: int,
}

// ---------------------------------------------------------------------------
// Path params
// ---------------------------------------------------------------------------

param :: proc(b: ^Bifrost, key: string) -> (string, bool) {
	v, ok := b.params[key]
	return v, ok
}

param_int :: proc(b: ^Bifrost, key: string) -> (int, bool) {
	s, ok := b.params[key]
	if !ok {
		return 0, false
	}
	return strconv.parse_int(s)
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

text :: proc(b: ^Bifrost, status: int, body: string) {
	write_response(b, status, "text/plain; charset=utf-8", body)
}

json :: proc(b: ^Bifrost, status: int, v: any) {
	data, err := json.marshal(v, {}, context.temp_allocator)
	if err != nil {
		write_response(b, 500, "text/plain; charset=utf-8", "json marshal error")
		return
	}
	write_response(b, status, "application/json", string(data))
}

not_found :: proc(b: ^Bifrost) {
	text(b, 404, "404 not found")
}

set_header :: proc(b: ^Bifrost, key, value: string) {
	if b.headers == nil {
		b.headers = make(map[string]string, context.temp_allocator)
	}
	b.headers[key] = value
}
