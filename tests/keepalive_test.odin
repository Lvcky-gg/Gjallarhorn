package tests

// keepalive_test.odin — connection reuse and idle timeout (GH-006).
// Run with: odin test ./tests

import "core:net"
import "core:time"
import "core:testing"
import gh "../gjallarhorn"

@(test)
keep_alive_reuses_socket :: proc(t: ^testing.T) {
	server, client, paired := open_pair(t)
	if !paired {
		return
	}
	defer net.close(server)
	defer net.close(client)

	// Two pipelined requests on one socket: the first keeps it alive (HTTP/1.1
	// default), the second asks to close.
	reqs := "GET /a HTTP/1.1\r\nHost: x\r\n\r\n" + "GET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
	_, serr := net.send_tcp(client, transmute([]u8)reqs)
	testing.expect(t, serr == nil)

	conn := gh.Conn {
		socket = server,
		buf    = make([dynamic]u8, context.temp_allocator),
	}

	b1, c1, _, ok1, closed1 := gh.read_request(&conn, 1 << 20)
	testing.expect(t, ok1 && !closed1, "first request should parse")
	testing.expect_value(t, b1.path, "/a")
	testing.expect(t, b1.keep_alive, "HTTP/1.1 with no Connection header keeps alive")
	gh.conn_consume(&conn, c1)

	b2, c2, _, ok2, closed2 := gh.read_request(&conn, 1 << 20)
	testing.expect(t, ok2 && !closed2, "second request should parse from carried-over bytes")
	testing.expect_value(t, b2.path, "/b")
	testing.expect(t, !b2.keep_alive, "Connection: close ends the session")
	gh.conn_consume(&conn, c2)
}

@(test)
idle_socket_times_out :: proc(t: ^testing.T) {
	server, client, paired := open_pair(t)
	if !paired {
		return
	}
	defer net.close(server)
	defer net.close(client)

	// A short receive timeout stands in for IDLE_TIMEOUT; no data is ever sent.
	net.set_option(net.Any_Socket(server), .Receive_Timeout, 100 * time.Millisecond)
	conn := gh.Conn {
		socket = server,
		buf    = make([dynamic]u8, context.temp_allocator),
	}
	_, _, _, ok, closed := gh.read_request(&conn, 1 << 20)
	testing.expect(t, closed, "an idle socket should report closed")
	testing.expect(t, !ok)
}

@(test)
keep_alive_defaults :: proc(t: ^testing.T) {
	none := make(map[string]string, context.temp_allocator)
	close_hdr := make(map[string]string, context.temp_allocator)
	close_hdr["connection"] = "close"
	alive_hdr := make(map[string]string, context.temp_allocator)
	alive_hdr["connection"] = "keep-alive"

	testing.expect(t, gh.keep_alive_wanted("HTTP/1.1", none), "1.1 defaults to keep-alive")
	testing.expect(t, !gh.keep_alive_wanted("HTTP/1.1", close_hdr), "1.1 + close -> close")
	testing.expect(t, !gh.keep_alive_wanted("HTTP/1.0", none), "1.0 defaults to close")
	testing.expect(t, gh.keep_alive_wanted("HTTP/1.0", alive_hdr), "1.0 + keep-alive -> reuse")
}
