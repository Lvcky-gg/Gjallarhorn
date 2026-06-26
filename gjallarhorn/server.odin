package gjallarhorn

// server.odin — the socket loop: listen, accept, read, parse the request line,
// then hand the Bifrost to the rune chain.

import "core:net"
import "core:fmt"
import "core:strings"
import "core:strconv"

run :: proc(app: ^App) {

	if app.postgres.dbname != "" && !app.pg.open {
		if connect(app) {
			fmt.printfln("mimir: connected to postgres %s/%s", app.postgres.host, app.postgres.dbname)
		} else {
			fmt.eprintln("mimir: postgres unavailable — migrations will print only")
		}
	}

	migrate(app)

	endpoint := net.Endpoint {
		address = net.IP4_Loopback,
		port    = app.port,
	}

	sock, err := net.listen_tcp(endpoint)
	if err != nil {
		fmt.eprintfln("gjallarhorn: listen failed on port %d: %v", app.port, err)
		return
	}
	defer net.close(sock)

	fmt.printfln("gjallarhorn: listening on http://127.0.0.1:%d", app.port)

	for {
		client, _, accept_err := net.accept_tcp(sock)
		if accept_err != nil {
			fmt.eprintfln("gjallarhorn: accept error: %v", accept_err)
			continue
		}
		handle_connection(app, client)
		net.close(client)
		free_all(context.temp_allocator)
	}
}


READ_CHUNK :: 4096   // bytes pulled per recv
MAX_HEADER :: 64 * 1024 // upper bound on the request + header block

handle_connection :: proc(app: ^App, client: net.TCP_Socket) {
	b, status, ok := recv_request(client, app.max_body, context.temp_allocator)
	if !ok {
		send_raw(client, status, fmt.tprintf("%d %s", status, status_text(status)))
		return
	}
	b._app = app
	next(&b)
}

// recv_request reads and parses a complete HTTP request: the request line, the
// header block, and a body sized by Content-Length (read across as many TCP
// segments as it takes). On a protocol error it returns ok=false plus the HTTP
// status the caller should send back (400, or 413 when the body exceeds
// max_body). The returned Bifrost has no `_app`; the caller wires that.
recv_request :: proc(
	client: net.TCP_Socket,
	max_body: int,
	allocator := context.allocator,
) -> (
	b: Bifrost,
	status: int,
	ok: bool,
) {
	acc := make([dynamic]u8, allocator)
	chunk: [READ_CHUNK]u8

	// Phase 1: read until the blank line that terminates the header block.
	header_end := -1
	for {
		n, recv_err := net.recv_tcp(client, chunk[:])
		if recv_err != nil || n == 0 {
			break
		}
		append(&acc, ..chunk[:n])
		if idx := strings.index(string(acc[:]), "\r\n\r\n"); idx >= 0 {
			header_end = idx
			break
		}
		if len(acc) > MAX_HEADER {
			return {}, 400, false
		}
	}
	if header_end < 0 {
		return {}, 400, false
	}

	head := string(acc[:header_end])

	// Request line: METHOD SP TARGET SP HTTP/1.1
	line_end := strings.index(head, "\r\n")
	if line_end < 0 {
		line_end = len(head)
	}
	parts := strings.split(head[:line_end], " ", allocator)
	if len(parts) < 2 {
		return {}, 400, false
	}
	method, method_ok := parse_method(parts[0])
	if !method_ok {
		return {}, 400, false
	}

	// Strip query string; routing is on path only for now.
	path := parts[1]
	if q := strings.index(path, "?"); q >= 0 {
		path = path[:q]
	}

	// Headers run from just past the request line to the blank line.
	req_headers: map[string]string
	if line_end + 2 <= len(head) {
		hdrs, hok := parse_headers(head[line_end + 2:], allocator)
		if !hok {
			return {}, 400, false
		}
		req_headers = hdrs
	}

	// Phase 2: body. Content-Length tells us how many bytes to expect; absent
	// it, the body is whatever already arrived alongside the headers.
	body_start := header_end + 4
	content_length := len(acc) - body_start
	if cl, has_cl := req_headers["content-length"]; has_cl {
		parsed, pok := strconv.parse_int(strings.trim_space(cl))
		if !pok || parsed < 0 {
			return {}, 400, false
		}
		content_length = parsed
	}
	if content_length > max_body {
		return {}, 413, false
	}

	for len(acc) - body_start < content_length {
		n, recv_err := net.recv_tcp(client, chunk[:])
		if recv_err != nil || n == 0 {
			break // client closed early; hand back what we have
		}
		append(&acc, ..chunk[:n])
	}

	end := body_start + min(content_length, len(acc) - body_start)
	body := acc[body_start:end]

	b = Bifrost {
		method      = method,
		path        = path,
		req_headers = req_headers,
		body        = body,
		body_text   = string(body),
		client      = client,
	}
	return b, 0, true
}
