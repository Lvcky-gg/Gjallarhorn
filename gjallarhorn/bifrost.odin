package gjallarhorn


import "core:net"
import "core:strconv"
import "core:strings"
import "core:encoding/json"

Bifrost :: struct {
	method:      Method,
	path:        string,
	params:      map[string]string,
	query:       map[string]string, // URL-decoded query-string params

	headers:     map[string]string, // response headers
	cookies:     [dynamic]string,   // response Set-Cookie lines (one per cookie)
	req_headers: map[string]string, // request headers, keys lower-cased
	body:        []u8,              // raw request body
	body_text:   string,            // body as a string view
	client:      net.TCP_Socket,
	ssl:         rawptr, // TLS session when serving HTTPS; nil for plaintext (GH-054)
	written:     bool,
	keep_alive:  bool,              // reuse the socket after this response

	// Chain state, driven by `next`. Underscored: not for handler use.
	_app:      ^App,
	_mw_index: int,

	// Session state, lazily loaded from the signed cookie on first access.
	_session:        map[string]string,
	_session_loaded: bool,
}


param :: proc(b: ^Bifrost, key: string) -> (string, bool) {
	v, ok := b.params[key]
	return v, ok
}

// query reads a URL-decoded query-string param. Part of the `query` overload
// group (see query_well for the database statement runner).
query_param :: proc(b: ^Bifrost, key: string) -> (string, bool) {
	v, ok := b.query[key]
	return v, ok
}

query :: proc {
	query_well,
	query_param,
}

param_int :: proc(b: ^Bifrost, key: string) -> (int, bool) {
	s, ok := b.params[key]
	if !ok {
		return 0, false
	}
	return strconv.parse_int(s)
}

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

// header reads a request header by name. Lookup is case-insensitive; parsed
// keys are stored lower-cased, so the supplied key is lower-cased to match.
header :: proc(b: ^Bifrost, key: string) -> (string, bool) {
	lk := strings.to_lower(key, context.temp_allocator)
	v, ok := b.req_headers[lk]
	return v, ok
}

// parse_headers splits a CRLF-delimited header block into a map keyed by
// lower-cased field name. Returns ok=false on a malformed line (no colon or
// empty field name) so the caller can reject the request with a 400.
parse_headers :: proc(block: string, allocator := context.allocator) -> (headers: map[string]string, ok: bool) {
	headers = make(map[string]string, allocator)
	for line in strings.split(block, "\r\n", allocator) {
		if line == "" {
			continue
		}
		colon := strings.index(line, ":")
		if colon < 0 {
			return headers, false
		}
		name := strings.to_lower(strings.trim_space(line[:colon]), allocator)
		if name == "" {
			return headers, false
		}
		headers[name] = strings.trim_space(line[colon + 1:])
	}
	return headers, true
}

set_header :: proc(b: ^Bifrost, key, value: string) {
	if b.headers == nil {
		b.headers = make(map[string]string, context.temp_allocator)
	}
	b.headers[key] = value
}

// ---------------------------------------------------------------------------
// Cookies
// ---------------------------------------------------------------------------

Same_Site :: enum {
	Unset, // omit the attribute (browser default, currently Lax)
	Strict,
	Lax,
	None,
}

// Cookie_Options shapes a Set-Cookie. The zero value writes a session cookie
// scoped to "/" with no flags. Max_Age is a Maybe: nil omits the attribute
// (session cookie), 0 expires it immediately — the idiom for deletion.
Cookie_Options :: struct {
	path:      string, // defaults to "/" when empty
	domain:    string,
	max_age:   Maybe(int), // seconds
	http_only: bool,
	secure:    bool,
	same_site: Same_Site,
}

// cookie reads a cookie value from the request's `Cookie` header. Values are
// returned verbatim; a value carrying cookie-reserved characters (`;`, `,`,
// whitespace, `=`) should be encoded by the caller before set_cookie and decoded
// after cookie.
cookie :: proc(b: ^Bifrost, name: string) -> (string, bool) {
	raw, ok := b.req_headers["cookie"]
	if !ok {
		return "", false
	}
	for pair in strings.split(raw, ";", context.temp_allocator) {
		p := strings.trim_space(pair)
		eq := strings.index(p, "=")
		if eq < 0 {
			continue
		}
		if p[:eq] == name {
			return p[eq + 1:], true
		}
	}
	return "", false
}

// set_cookie queues a Set-Cookie header for the response. Each call adds its own
// header line, so multiple cookies coexist (unlike the single-valued header map).
set_cookie :: proc(b: ^Bifrost, name, value: string, opts := Cookie_Options{}) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, name)
	strings.write_byte(&sb, '=')
	strings.write_string(&sb, value)

	path := opts.path == "" ? "/" : opts.path
	strings.write_string(&sb, "; Path=")
	strings.write_string(&sb, path)

	if opts.domain != "" {
		strings.write_string(&sb, "; Domain=")
		strings.write_string(&sb, opts.domain)
	}
	if ma, has := opts.max_age.?; has {
		strings.write_string(&sb, "; Max-Age=")
		strings.write_int(&sb, ma)
	}
	switch opts.same_site {
	case .Strict:
		strings.write_string(&sb, "; SameSite=Strict")
	case .Lax:
		strings.write_string(&sb, "; SameSite=Lax")
	case .None:
		strings.write_string(&sb, "; SameSite=None")
	case .Unset:
	}
	if opts.http_only {
		strings.write_string(&sb, "; HttpOnly")
	}
	if opts.secure {
		strings.write_string(&sb, "; Secure")
	}

	if b.cookies == nil {
		b.cookies = make([dynamic]string, context.temp_allocator)
	}
	append(&b.cookies, strings.to_string(sb))
}
