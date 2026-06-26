package tests

// recover_test.odin — a panicking handler is caught and turned into a 500
// without taking down the worker (GH-011). Run with: odin test ./tests

import "core:net"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

boom_handler :: proc(b: ^gh.Bifrost) {
	panic("intentional handler explosion")
}

ok_handler :: proc(b: ^gh.Bifrost) {
	gh.text(b, 200, "ok")
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
