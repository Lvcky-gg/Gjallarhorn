package gjallarhorn

// router.odin — routes, the method verbs, and request dispatch.

import "core:strings"


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

dispatch_route :: proc(b: ^Bifrost) {
	for route in b._app.routes {
		if route.method != b.method {
			continue
		}
		if params, ok := match_path(route.path, b.path); ok {
			b.params = params
			// Hand the handler a decoded path to match its decoded params.
			b.path = percent_decode(b.path)
			route.handler(b)
			return
		}
	}

	// Mounts (GET only). First mount whose prefix matches handles it; template
	// mounts are tried before raw static ones.
	if b.method == .Get {
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
