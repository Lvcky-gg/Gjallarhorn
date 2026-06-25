package gjallarhorn

// middleware.odin — the Rune chain. A middleware (a "Rune") wraps the rest of
// the pipeline. Because Odin has no closures, the remaining chain is threaded
// through the Bifrost (a cursor), not captured.

import "core:fmt"

Next :: proc(b: ^Bifrost)
Middleware :: proc(b: ^Bifrost, next: Next)

// rune: inscribe a middleware onto the app. Runes run in registration order,
// onion-style — outermost registered first, each wrapping everything after it.
rune :: proc(app: ^App, mw: Middleware) {
	append(&app.middleware, mw)
}

// next: advance the rune chain, then terminate in route dispatch. This is the
// `Next` value handed to every middleware; calling it runs the next layer.
next :: proc(b: ^Bifrost) {
	if b._mw_index < len(b._app.middleware) {
		mw := b._app.middleware[b._mw_index]
		b._mw_index += 1
		mw(b, next)
		return
	}
	dispatch_route(b)
}

// ---------------------------------------------------------------------------
// Built-in runes
// ---------------------------------------------------------------------------

// cors: allow cross-origin requests and answer preflight OPTIONS directly.
cors :: proc(b: ^Bifrost, next: Next) {
	set_header(b, "Access-Control-Allow-Origin", "*")
	set_header(b, "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
	if b.method == .Options {
		text(b, 204, "") // short-circuit: do not call next
		return
	}
	next(b)
}

// logger: one line per request. Runs code on the way in; the post-`next`
// position is where response logging/timing would go.
logger :: proc(b: ^Bifrost, next: Next) {
	fmt.printfln("→ %v %s", b.method, b.path)
	next(b)
}
