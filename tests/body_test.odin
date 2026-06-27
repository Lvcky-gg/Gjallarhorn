package tests

// body_test.odin — full request body assembly across TCP segments via the
// Content-Length loop. Run with: odin test ./tests

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

// dial a server bound on an ephemeral loopback port, returning both ends.
open_pair :: proc(t: ^testing.T) -> (server: net.TCP_Socket, client: net.TCP_Socket, ok: bool) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if lerr != nil {
		testing.expectf(t, false, "listen failed: %v", lerr)
		return {}, {}, false
	}
	defer net.close(listener)

	ep, eerr := net.bound_endpoint(net.Any_Socket(listener))
	if eerr != nil {
		testing.expectf(t, false, "bound_endpoint failed: %v", eerr)
		return {}, {}, false
	}

	// dial completes the handshake into the backlog; no accept needed yet.
	derr: net.Network_Error
	client, derr = net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = ep.port})
	if derr != nil {
		testing.expectf(t, false, "dial failed: %v", derr)
		return {}, {}, false
	}

	aerr: net.Network_Error
	server, _, aerr = net.accept_tcp(listener)
	if aerr != nil {
		net.close(client)
		testing.expectf(t, false, "accept failed: %v", aerr)
		return {}, {}, false
	}
	return server, client, true
}

@(test)
body_large_roundtrip :: proc(t: ^testing.T) {
	server, client, ok := open_pair(t)
	if !ok {
		return
	}
	defer net.close(server)
	defer net.close(client)

	// A body well past the old 8 KiB single-read ceiling.
	payload := strings.repeat("x", 20_000, context.temp_allocator)
	req := fmt.tprintf(
		"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n%s",
		len(payload),
		payload,
	)
	_, serr := net.send_tcp(client, transmute([]u8)req)
	testing.expect(t, serr == nil, "send should succeed")

	conn := gh.Conn {
		socket = server,
		buf    = make([dynamic]u8, context.temp_allocator),
	}
	b, _, status, rok, closed := gh.read_request(&conn, 1 << 20)
	testing.expect(t, rok, "request should parse")
	testing.expect(t, !closed)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, len(b.body), len(payload))
	testing.expect_value(t, b.body_text, payload)

	cl, has_cl := gh.header(&b, "content-length")
	testing.expect(t, has_cl)
	testing.expect_value(t, cl, "20000")
}

@(test)
body_over_limit_413 :: proc(t: ^testing.T) {
	server, client, ok := open_pair(t)
	if !ok {
		return
	}
	defer net.close(server)
	defer net.close(client)

	req := "POST /echo HTTP/1.1\r\nContent-Length: 5000\r\n\r\n"
	_, _ = net.send_tcp(client, transmute([]u8)req)

	// max_body below the declared Content-Length -> rejected, no body read.
	conn := gh.Conn {
		socket = server,
		buf    = make([dynamic]u8, context.temp_allocator),
	}
	_, _, status, rok, _ := gh.read_request(&conn, 1024)
	testing.expect(t, !rok, "oversized body should be rejected")
	testing.expect_value(t, status, 413)
}
