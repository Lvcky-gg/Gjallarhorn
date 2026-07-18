package tests

// recover_test.odin — a panicking handler is caught and turned into a 500
// without taking down the worker (GH-011). Run with: odin test ./tests

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import gh "../gjallarhorn"

boom_handler :: proc(b: ^gh.Bifrost) {
	panic("intentional handler explosion")
}

ok_handler :: proc(b: ^gh.Bifrost) {
	gh.text(b, 200, "ok")
}

@(test)
acquire_then_reclaim_balances_pool :: proc(t: ^testing.T) {
	// Exercise the real checkout path: pool_acquire records the borrow, then a
	// simulated fault (longjmp) skips pool_release, and reclaim_borrowed_conns
	// hands the connection back. Without reclaim the pool would bleed capacity
	// until it deadlocks (GH-010). conn stays closed so reset_conn does no I/O.
	conns := make([]gh.Pg_Conn, 1)
	defer delete(conns)
	conns[0].idx = 0

	app: gh.App
	app.pool.conns = conns[:]
	app.pool.available = make([dynamic]int, 0, 1)
	append(&app.pool.available, 0)
	app.pool.size = 1
	app.pool.open = true
	sync.sema_post(&app.pool.sem) // one connection available to acquire

	clear(&gh.borrowed_conns)
	defer {delete(gh.borrowed_conns); gh.borrowed_conns = nil}

	conn, ok := gh.pool_acquire(&app.pool)
	testing.expect(t, ok, "acquire succeeds")
	testing.expect(t, conn == &conns[0], "hands out the free connection")
	testing.expect_value(t, len(gh.borrowed_conns), 1)  // acquire tracked the borrow
	testing.expect_value(t, len(app.pool.available), 0) // checked out of the pool

	// Fault path: pool_release never runs; reclaim is the safety net.
	gh.reclaim_borrowed_conns(&app)
	testing.expect_value(t, len(gh.borrowed_conns), 0)  // tracking cleared
	testing.expect_value(t, len(app.pool.available), 1) // returned to the pool

	delete(app.pool.available)
}

@(test)
handler_panic_becomes_500 :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	gh.get(&app, "/boom", boom_handler)
	gh.get(&app, "/ok", ok_handler)
	defer delete(app.routes)

	// First request: the handler panics. run_guarded must recover and reply 500.
	{
		server, client, ok := open_pair(t)
		if !ok {
			return
		}
		defer net.close(server)
		defer net.close(client)

		b := gh.Bifrost {
			method     = .Get,
			path       = "/boom",
			client     = server,
			keep_alive = true,
			_app       = &app,
		}
		gh.run_guarded(&b)

		testing.expect(t, b.written, "recovery should have written a response")
		testing.expect(t, !b.keep_alive, "a faulted request drops keep-alive")

		resp: [256]u8
		n, _ := net.recv_tcp(client, resp[:])
		testing.expect(t, strings.has_prefix(string(resp[:n]), "HTTP/1.1 500"), "panic -> 500")
	}

	// Second request on the same thread: recovery must re-arm, proving the
	// worker survived the panic rather than being left wedged.
	{
		server, client, ok := open_pair(t)
		if !ok {
			return
		}
		defer net.close(server)
		defer net.close(client)

		b := gh.Bifrost {
			method = .Get,
			path   = "/ok",
			client = server,
			_app   = &app,
		}
		gh.run_guarded(&b)

		resp: [256]u8
		n, _ := net.recv_tcp(client, resp[:])
		testing.expect(t, strings.has_prefix(string(resp[:n]), "HTTP/1.1 200"), "server still serves after a panic")
	}
}
