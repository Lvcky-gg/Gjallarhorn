package gjallarhorn

// router.odin — routes, the method verbs, and request dispatch.

import "core:strings"


Handler :: proc(b: ^Bifrost)

// Ward is a route guard (Old Norse vǫrðr, "watcher"). It runs after the path
// matches but before the handler, and returns true to let the request through.
// On a false return the handler is skipped; the ward should write its own
// response (401/403 as fits), and dispatch falls back to 401 if it wrote nothing.
Ward :: proc(b: ^Bifrost) -> bool

Method :: enum {
	Get,
	Post,
	Put,
	Patch,
	Delete,
	Head,
	Options,
}

Route :: struct {
	method:  Method,
	path:    string, // pattern, may contain :params, e.g. "/sample/:id"
	handler: Handler,
	ward:    Ward, // optional guard; nil = open route
}


get :: proc(app: ^App, path: string, handler: Handler, ward: Ward = nil) {
	append(&app.routes, Route{method = .Get, path = path, handler = handler, ward = ward})
}

post :: proc(app: ^App, path: string, handler: Handler, ward: Ward = nil) {
	append(&app.routes, Route{method = .Post, path = path, handler = handler, ward = ward})
}

put :: proc(app: ^App, path: string, handler: Handler, ward: Ward = nil) {
	append(&app.routes, Route{method = .Put, path = path, handler = handler, ward = ward})
}

delete :: proc(app: ^App, path: string, handler: Handler, ward: Ward = nil) {
	append(&app.routes, Route{method = .Delete, path = path, handler = handler, ward = ward})
}

patch :: proc(app: ^App, path: string, handler: Handler, ward: Ward = nil) {
	append(&app.routes, Route{method = .Patch, path = path, handler = handler, ward = ward})
}

// head registers an explicit HEAD handler. Usually unnecessary: a HEAD with no
// explicit handler is answered by the matching GET route with the body dropped
// (see dispatch_route), which is the RFC-correct default.
head :: proc(app: ^App, path: string, handler: Handler, ward: Ward = nil) {
	append(&app.routes, Route{method = .Head, path = path, handler = handler, ward = ward})
}

// options registers an explicit OPTIONS handler. Note the built-in `cors` rune
// already answers preflight OPTIONS with 204 before dispatch, so this matters
// only for apps not using that rune.
options :: proc(app: ^App, path: string, handler: Handler, ward: Ward = nil) {
	append(&app.routes, Route{method = .Options, path = path, handler = handler, ward = ward})
}

dispatch_route :: proc(b: ^Bifrost) {
	// HEAD is answered exactly like GET but with the payload suppressed at write
	// time (RFC 7231 §4.3.2): same headers, same Content-Length, no body.
	b.omit_body = b.method == .Head

	// Exact method match first — this also serves an explicitly registered HEAD
	// or OPTIONS route.
	for route in b._app.routes {
		if route.method != b.method {
			continue
		}
		if params, ok := match_path(route.path, b.path); ok {
			run_matched_route(b, route, params)
			return
		}
	}

	// HEAD with no explicit HEAD route: answer it with the matching GET route.
	// omit_body (set above) makes write_response drop the payload.
	if b.method == .Head {
		for route in b._app.routes {
			if route.method != .Get {
				continue
			}
			if params, ok := match_path(route.path, b.path); ok {
				run_matched_route(b, route, params)
				return
			}
		}
	}

	// Mounts serve GET, and HEAD over the same files. First mount whose prefix
	// matches handles it; template mounts are tried before raw static ones.
	if b.method == .Get || b.method == .Head {
		for mount in b._app.looms {
			if under_prefix(b.path, mount.url_prefix) {
				if serve_loom(b, mount) {
					return
				}
			}
		}
		for mount in b._app.statics {
			if under_prefix(b.path, mount.url_prefix) {
				if serve_static(b, mount) {
					return
				}
			}
		}
	}

	not_found(b)
}

// run_matched_route runs a matched route's ward (if any) then its handler,
// sharing the path-decode + ward-fallback logic between the exact-match and the
// HEAD→GET fallback passes.
run_matched_route :: proc(b: ^Bifrost, route: Route, params: map[string]string) {
	b.params = params
	// Hand the handler a decoded path to match its decoded params.
	b.path = percent_decode(b.path)
	// A ward guards the handler: deny stops here (with a 401 fallback if the ward
	// wrote nothing), allow falls through to the handler.
	if route.ward != nil && !route.ward(b) {
		if !b.written {
			text(b, 401, "401 unauthorized")
		}
		return
	}
	route.handler(b)
}

// Segment-wise match. ":name" segments capture into params.
match_path :: proc(pattern, path: string) -> (params: map[string]string, ok: bool) {
	p_segs := strings.split(strings.trim(pattern, "/"), "/", context.temp_allocator)
	u_segs := strings.split(strings.trim(path, "/"), "/", context.temp_allocator)
	if len(p_segs) != len(u_segs) {
		return nil, false
	}

	params = make(map[string]string, context.temp_allocator)
	for seg, i in p_segs {
		if len(seg) > 0 && seg[0] == ':' {
			// Capture the decoded value; matching stays on raw segments so an
			// encoded slash (%2F) can't smuggle in an extra path segment.
			params[seg[1:]] = percent_decode(u_segs[i])
		} else if seg != u_segs[i] {
			return nil, false
		}
	}
	return params, true
}

parse_method :: proc(s: string) -> (Method, bool) {
	switch s {
	case "GET":
		return .Get, true
	case "POST":
		return .Post, true
	case "PUT":
		return .Put, true
	case "PATCH":
		return .Patch, true
	case "DELETE":
		return .Delete, true
	case "HEAD":
		return .Head, true
	case "OPTIONS":
		return .Options, true
	}
	return .Get, false
}
