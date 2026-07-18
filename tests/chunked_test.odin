package tests

// chunked_test.odin — Transfer-Encoding: chunked request bodies and the
// request-smuggling defenses around them (GH-025). Chunked framing must decode
// the body AND consume exactly its bytes, so a pipelined follow-up request can't
// be smuggled in the leftover. Run with: odin test ./tests

import "core:net"
import "core:testing"
import gh "../gjallarhorn"

@(test)
chunked_body_decodes_and_frames :: proc(t: ^testing.T) {
	server, client, paired := open_pair(t)
	if !paired {
		return
	}
	defer net.close(server)
	defer net.close(client)

	// A chunked POST, then a pipelined plain GET. If the chunked framing consumes
	// the wrong number of bytes, the GET is corrupted — the smuggling failure.
	req :: "POST /u HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" +
		"5\r\nhello\r\n" + "6\r\n world\r\n" + "0\r\n\r\n"
	next :: "GET /next HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
	whole: string = req + next
	_, serr := net.send_tcp(client, transmute([]u8)whole)
	testing.expect(t, serr == nil)

	conn := gh.Conn {
		socket = server,
		buf    = make([dynamic]u8, context.temp_allocator),
	}

	b1, c1, _, ok1, closed1 := gh.read_request(&conn, 1 << 20)
	testing.expect(t, ok1 && !closed1, "chunked request should parse")
	testing.expect_value(t, b1.path, "/u")
	testing.expect_value(t, b1.body_text, "hello world")
	gh.conn_consume(&conn, c1)

	b2, c2, _, ok2, closed2 := gh.read_request(&conn, 1 << 20)
	testing.expect(t, ok2 && !closed2, "pipelined next request must survive intact")
	testing.expect_value(t, b2.path, "/next")
	gh.conn_consume(&conn, c2)
}

@(test)
chunked_trailer_is_consumed :: proc(t: ^testing.T) {
	// A trailer after the last chunk must be consumed too, or it desyncs the next
	// request.
	server, client, paired := open_pair(t)
	if !paired {
		return
	}
	defer net.close(server)
	defer net.close(client)

	req :: "POST /u HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" +
		"3\r\nabc\r\n" + "0\r\nX-Trailer: v\r\n\r\n"
	next :: "GET /after HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
	whole: string = req + next
	net.send_tcp(client, transmute([]u8)whole)

	conn := gh.Conn {
		socket = server,
		buf    = make([dynamic]u8, context.temp_allocator),
	}

	b1, c1, _, ok1, _ := gh.read_request(&conn, 1 << 20)
	testing.expect(t, ok1, "chunked+trailer should parse")
	testing.expect_value(t, b1.body_text, "abc")
	gh.conn_consume(&conn, c1)

	b2, c2, _, ok2, _ := gh.read_request(&conn, 1 << 20)
	testing.expect(t, ok2, "request after a trailer should parse")
	testing.expect_value(t, b2.path, "/after")
	gh.conn_consume(&conn, c2)
}

@(test)
chunked_with_content_length_rejected :: proc(t: ^testing.T) {
	// Both Transfer-Encoding and Content-Length: ambiguous, reject (RFC 7230).
	server, client, paired := open_pair(t)
	if !paired {
		return
	}
	defer net.close(server)
	defer net.close(client)

	req := "POST /u HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
	net.send_tcp(client, transmute([]u8)req)

	conn := gh.Conn {
		socket = server,
		buf    = make([dynamic]u8, context.temp_allocator),
	}
	_, _, status, ok, _ := gh.read_request(&conn, 1 << 20)
	testing.expect(t, !ok, "CL + TE together must be rejected")
	testing.expect_value(t, status, 400)
}

@(test)
unsupported_transfer_encoding_rejected :: proc(t: ^testing.T) {
	// A coding we don't implement is refused (501), never mis-framed.
	server, client, paired := open_pair(t)
	if !paired {
		return
	}
	defer net.close(server)
	defer net.close(client)

	req := "POST /u HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n0\r\n\r\n"
	net.send_tcp(client, transmute([]u8)req)

	conn := gh.Conn {
		socket = server,
		buf    = make([dynamic]u8, context.temp_allocator),
	}
	_, _, status, ok, _ := gh.read_request(&conn, 1 << 20)
	testing.expect(t, !ok, "unsupported Transfer-Encoding must be rejected")
	testing.expect_value(t, status, 501)
}
