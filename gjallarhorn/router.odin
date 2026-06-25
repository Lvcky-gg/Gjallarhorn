package gjallarhorn

// router.odin — routes, the method verbs, and request dispatch.

import "core:strings"

// Style A (decided): handlers are free procedures. Odin has no methods, no
// UFCS and no closures, so there is no `self`/`app.Get(...)` to capture. The
// app is always passed explicitly by pointer.
Handler :: proc(b: ^Bifrost)

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
}

// ---------------------------------------------------------------------------
// Registration verbs
// ---------------------------------------------------------------------------

get :: proc(app: ^App, path: string, handler: Handler) {
	append(&app.routes, Route{method = .Get, path = path, handler = handler})
}

post :: proc(app: ^App, path: string, handler: Handler) {
	append(&app.routes, Route{method = .Post, path = path, handler = handler})
}

put :: proc(app: ^App, path: string, handler: Handler) {
	append(&app.routes, Route{method = .Put, path = path, handler = handler})
}

delete :: proc(app: ^App, path: string, handler: Handler) {
	append(&app.routes, Route{method = .Delete, path = path, handler = handler})
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

dispatch_route :: proc(b: ^Bifrost) {
	for route in b._app.routes {
		if route.method != b.method {
			continue
		}
		if params, ok := match_path(route.path, b.path); ok {
			b.params = params
			route.handler(b)
			return
		}
	}

	// Static mounts (GET only). First mount whose prefix matches handles it.
	if b.method == .Get {
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
			params[seg[1:]] = u_segs[i]
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
