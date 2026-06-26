package tests

// concurrency_test.odin — connections are handled off the accept thread, so a
// crowd of stalled clients can't starve a fast one (GH-010). Also exercises the
// per-worker temp allocator: many threads each run free_all on their own arena.
// Run with: odin test ./tests

import "core:net"
import "core:thread"
import "core:time"
import "core:testing"
import gh "../gjallarhorn"

fast_handler :: proc(b: ^gh.Bifrost) {
	gh.text(b, 200, "ok")
}

@(test)
slow_clients_dont_stall_fast :: proc(t: ^testing.T) {
	SLOW :: 16

	app := gh.new(gh.Config{})
	gh.get(&app, "/fast", fast_handler)
	defer delete(app.routes)

	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if lerr != nil {
		testing.expectf(t, false, "listen failed: %v", lerr)
		return
	}
	defer net.close(listener)
	ep, _ := net.bound_endpoint(net.Any_Socket(listener))

	clients: [dynamic]net.TCP_Socket
	workers: [dynamic]^thread.Thread
	defer {
		// Closing each client end unblocks its worker's recv, so every worker
		// (slow ones included) returns and can be joined deterministically.
		for c in clients {
			net.close(c)
		}
		for w in workers {
			thread.join(w)
			thread.destroy(w)
		}
		delete(clients)
		delete(workers)
	}

	// dial+accept one connection and hand the server side to a worker thread.
	spin_up :: proc(t: ^testing.T, app: ^gh.App, listener: net.TCP_Socket, ep: net.Endpoint, clients: ^[dynamic]net.TCP_Socket, workers: ^[dynamic]^thread.Thread) -> (client: net.TCP_Socket, ok: bool) {
		c, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = ep.port})
		if derr != nil {
			testing.expectf(t, false, "dial failed: %v", derr)
			return {}, false
		}
		s, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			net.close(c)
			testing.expectf(t, false, "accept failed: %v", aerr)
			return {}, false
		}
		append(clients, c)
		append(workers, thread.create_and_start_with_poly_data2(app, s, gh.handle_worker))
		return c, true
	}

	// 16 slow clients: connected, holding a worker each, but never sending.
	for i in 0 ..< SLOW {
		if _, ok := spin_up(t, &app, listener, ep, &clients, &workers); !ok {
			return
		}
	}

	// One fast client. With per-connection workers it is served immediately,
	// despite all SLOW workers being parked in recv.
	fast, ok := spin_up(t, &app, listener, ep, &clients, &workers)
	if !ok {
		return
	}
	net.set_option(net.Any_Socket(fast), .Receive_Timeout, 5 * time.Second)

	start := time.now()
	_, serr := net.send_tcp(fast, transmute([]u8)string("GET /fast HTTP/1.1\r\nConnection: close\r\n\r\n"))
	testing.expect(t, serr == nil)

	resp: [256]u8
	n, rerr := net.recv_tcp(fast, resp[:])
	elapsed := time.since(start)

	testing.expect(t, rerr == nil, "fast client should get a reply, not time out")
	testing.expect(t, n > 0)
	testing.expect(
		t,
		string(resp[:min(n, 12)]) == "HTTP/1.1 200",
		"fast request served while slow clients are parked",
	)
	testing.expect(t, elapsed < time.Second, "fast response should not be stalled by slow peers")
}
