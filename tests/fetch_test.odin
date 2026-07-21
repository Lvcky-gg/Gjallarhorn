package tests

// fetch_test.odin — the outbound HTTP client (fetch.odin). A canned server runs
// on a loopback port in a worker thread and fetch calls it, so the whole path
// (dial, send, read-to-EOF, parse, de-chunk) is exercised without the network or
// TLS. Run with: odin test ./tests

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import gh "../gjallarhorn"

// Canned holds a listening socket, the response to send, and a buffer the server
// thread fills with the request it received (so tests can assert on it).
Canned :: struct {
	listener: net.TCP_Socket,
	response: string,
	req_buf:  [8192]u8,
	req_len:  int,
}

serve_once :: proc(c: ^Canned) {
	client, _, aerr := net.accept_tcp(c.listener)
	if aerr != nil {
		return
	}
	// Read the request: headers, then a Content-Length body if present.
	for c.req_len < len(c.req_buf) {
		n, err := net.recv_tcp(client, c.req_buf[c.req_len:])
		if err != nil || n == 0 {
			break
		}
		c.req_len += n
		got := string(c.req_buf[:c.req_len])
		if he := strings.index(got, "\r\n\r\n"); he >= 0 {
			cl := 0
			for line in strings.split(got[:he], "\r\n", context.temp_allocator) {
				if strings.has_prefix(strings.to_lower(line, context.temp_allocator), "content-length:") {
					cl, _ = strconv.parse_int(strings.trim_space(line[15:]))
				}
			}
			if c.req_len >= he + 4 + cl {
				break
			}
		}
	}
	net.send_tcp(client, transmute([]u8)c.response)
	net.close(client)
	net.close(c.listener)
}

// start_canned begins listening (so a dial always connects), spawns the responder
// thread, and returns the port plus the Canned to join/inspect.
start_canned :: proc(t: ^testing.T, response: string) -> (port: int, c: ^Canned, th: ^thread.Thread, ok: bool) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if lerr != nil {
		testing.expectf(t, false, "listen failed: %v", lerr)
		return 0, nil, nil, false
	}
	ep, _ := net.bound_endpoint(net.Any_Socket(listener))
	c = new(Canned, context.temp_allocator)
	c.listener = listener
	c.response = response
	th = thread.create_and_start_with_poly_data(c, serve_once, self_cleanup = false)
	return ep.port, c, th, true
}

@(test)
fetch_get_content_length :: proc(t: ^testing.T) {
	resp :: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"ok\":true}\r\n"
	port, c, th, ok := start_canned(t, resp)
	if !ok {return}
	defer thread.destroy(th)

	res, fok := gh.fetch(fmt.tprintf("http://127.0.0.1:%d/thing", port))
	thread.join(th)

	testing.expect(t, fok, "fetch succeeds")
	testing.expect_value(t, res.status, 200)
	testing.expect_value(t, res.headers["content-type"], "application/json")
	testing.expect_value(t, res.body, "{\"ok\":true}\r\n")
	// The server saw a well-formed GET with a Host header.
	testing.expect(t, strings.has_prefix(string(c.req_buf[:c.req_len]), "GET /thing HTTP/1.1"), "request line")
	testing.expect(t, strings.contains(string(c.req_buf[:c.req_len]), "Host: 127.0.0.1"), "host header")
}

@(test)
fetch_dechunks_response :: proc(t: ^testing.T) {
	// A chunked response is reassembled: "Wait" + "less".
	resp :: "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWait\r\n4\r\nless\r\n0\r\n\r\n"
	port, _, th, ok := start_canned(t, resp)
	if !ok {return}
	defer thread.destroy(th)

	res, fok := gh.fetch(fmt.tprintf("http://127.0.0.1:%d/", port))
	thread.join(th)
	testing.expect(t, fok)
	testing.expect_value(t, res.status, 200)
	testing.expect_value(t, res.body, "Waitless")
}

@(test)
fetch_post_sends_body :: proc(t: ^testing.T) {
	resp :: "HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nhi"
	port, c, th, ok := start_canned(t, resp)
	if !ok {return}
	defer thread.destroy(th)

	req := gh.Fetch_Request {
		method = "POST",
		body   = "hello=world",
	}
	res, fok := gh.fetch(fmt.tprintf("http://127.0.0.1:%d/submit", port), req)
	thread.join(th)

	testing.expect(t, fok)
	testing.expect_value(t, res.status, 201)
	got := string(c.req_buf[:c.req_len])
	testing.expect(t, strings.has_prefix(got, "POST /submit HTTP/1.1"), "POST request line")
	testing.expect(t, strings.contains(got, "Content-Length: 11"), "content-length set")
	testing.expect(t, strings.has_suffix(got, "hello=world"), "body sent")
}

@(test)
fetch_url_parse :: proc(t: ^testing.T) {
	s, h, p, path, ok := gh.parse_fetch_url("https://api.example.com/v1/x?a=b")
	testing.expect(t, ok)
	testing.expect_value(t, s, "https")
	testing.expect_value(t, h, "api.example.com")
	testing.expect_value(t, p, 443) // default https port
	testing.expect_value(t, path, "/v1/x?a=b") // query kept

	_, _, p2, _, _ := gh.parse_fetch_url("http://localhost:9000/")
	testing.expect_value(t, p2, 9000)

	_, _, _, path3, _ := gh.parse_fetch_url("http://host") // no path -> "/"
	testing.expect_value(t, path3, "/")

	_, _, _, _, bad := gh.parse_fetch_url("ftp://nope")
	testing.expect(t, !bad, "non-http scheme rejected")
}

@(test)
fetch_https_needs_tls_build :: proc(t: ^testing.T) {
	// In a default (non-TLS) build, an https fetch fails fast rather than trying
	// plaintext. (Under -define:GJ_TLS=true this path would attempt a handshake.)
	when !gh.GJ_TLS {
		_, ok := gh.fetch("https://example.com/")
		testing.expect(t, !ok, "https without a TLS build is refused")
	}
}

