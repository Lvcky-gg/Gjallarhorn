package gjallarhorn

// middleware.odin — the Rune chain. A middleware (a "Rune") wraps the rest of
// the pipeline. Because Odin has no closures, the remaining chain is threaded
// through the Bifrost (a cursor), not captured.

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:time"

Next :: proc(b: ^Bifrost)
Middleware :: proc(b: ^Bifrost, next: Next)

// Panic recovery (GH-011). Odin has no native `recover`, so we route runtime
// faults (panic, failed assert, bounds/nil checks) through a custom assertion
// handler that longjmps back to a setjmp checkpoint armed per request. These
// are thread-local: each worker recovers independently (see GH-010).
@(thread_local) panic_jmp: libc.jmp_buf
@(thread_local) panic_armed: bool

// recovery_failure_proc replaces the default abort-the-process handler on
// worker threads: it logs the fault, then unwinds to the armed checkpoint.
// Outside a guarded section it falls back to the default (which aborts).
recovery_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	logft(.Error, "gjallarhorn", "recovered handler panic at %v: %s%s", loc, prefix, message)
	if panic_armed {
		panic_armed = false
		libc.longjmp(&panic_jmp, 1)
	}
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// run_guarded runs the rune chain for one request under panic recovery. A
// panic in any middleware or handler unwinds back here; we answer 500 (unless a
// partial response already went out) and drop keep-alive so the connection is
// closed rather than reused with corrupt framing.
run_guarded :: proc(b: ^Bifrost) {
	context.assertion_failure_proc = recovery_failure_proc
	panic_armed = true
	defer panic_armed = false

	if libc.setjmp(&panic_jmp) == 0 {
		next(b)
	} else {
		// Resumed here via longjmp: a handler faulted mid-request.
		b.keep_alive = false
		if !b.written {
			write_response(b, 500, "text/plain; charset=utf-8", "500 internal server error")
		}
	}

	// Hand back any pool connection still checked out to this worker. A no-op on
	// the normal path (releases already ran); the safety net after a longjmp,
	// which skips the deferred/explicit releases and would otherwise bleed the
	// pool until it deadlocks (GH-010).
	reclaim_borrowed_conns(b._app)
}

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

// logger: one leveled, structured line per request. The line is emitted after
// `next` returns — the post-next position — so it reports the final status and
// how long the whole chain took. The level is derived from the status (5xx
// Error, 4xx Warn, else Info), so error responses stand out and route to stderr.
logger :: proc(b: ^Bifrost, next: Next) {
	start := time.tick_now()
	next(b)
	dur_ms := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))

	level := log_level_for_status(b.status)
	if stream_color(level) {
		// Pretty (TTY): bold-cyan method, status colored by class, dim duration —
		// aligned so a column of requests scans cleanly.
		method := paint(true, "\e[1;36m", fmt.tprintf("%-6v", b.method))
		status := paint(true, status_sgr(b.status), fmt.tprintf("%d", b.status))
		dur := paint(true, ANSI_DIM, fmt.tprintf("%.2fms", dur_ms))
		logf(level, "%s %s  %s  %s", method, status, b.path, dur)
	} else {
		// Plain (piped): structured key=value the stable format keeps greppable.
		logf(level, "method=%v path=%q status=%d dur_ms=%.3f", b.method, b.path, b.status, dur_ms)
	}
}
