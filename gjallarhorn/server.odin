package gjallarhorn

// server.odin — the socket loop: listen, accept, read, parse the request line,
// then hand the Bifrost to the rune chain. Connections are kept alive and
// reused across requests per RFC 7230 (see handle_connection).

import "core:net"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:thread"
import "core:time"

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

	// One thread per connection. accept_tcp is the only thing the accept loop
	// blocks on; request handling (which may stall on a slow client) is pushed
	// onto a self-cleaning worker thread, so a slow peer never holds the loop.
	for {
		client, _, accept_err := net.accept_tcp(sock)
		if accept_err != nil {
			fmt.eprintfln("gjallarhorn: accept error: %v", accept_err)
			continue
		}
		thread.run_with_poly_data2(app, client, handle_worker)
	}
}

// handle_worker is the per-connection thread body. Each worker runs with its
// own context (and thus its own thread-local temp allocator), so the per-request
// free_all inside handle_connection only ever reclaims this worker's arena —
// safe under concurrency.
handle_worker :: proc(app: ^App, client: net.TCP_Socket) {
	handle_connection(app, client)
	net.close(client)
	free_all(context.temp_allocator)
}


READ_CHUNK :: 4096            // bytes pulled per recv
MAX_HEADER :: 64 * 1024       // upper bound on the request + header block
IDLE_TIMEOUT :: 15 * time.Second // how long a kept-alive socket may sit idle

// Conn wraps a client socket with a persistent read buffer. The buffer holds
// bytes already pulled off the socket but not yet consumed, so a request that
// arrives in the same packet as its predecessor (pipelining) is not lost when
// the connection is reused.
Conn :: struct {
	socket: net.TCP_Socket,
	buf:    [dynamic]u8,
}

handle_connection :: proc(app: ^App, client: net.TCP_Socket) {
	// An idle keep-alive socket must not pin the (single-threaded) accept loop
	// forever; recv then fails once the timeout elapses and we close.
	net.set_option(net.Any_Socket(client), .Receive_Timeout, IDLE_TIMEOUT)

	conn := Conn {
		socket = client,
		buf    = make([dynamic]u8),
	}
	defer delete_dynamic_array(conn.buf) // builtin; package `delete` is the route verb

	for {
		b, consumed, status, ok, closed := read_request(&conn, app.max_body)
		if closed {
			return // idle timeout, EOF, or a truncated request
		}
		if !ok {
			send_raw(client, status, fmt.tprintf("%d %s", status, status_text(status)))
			return
		}

		b._app = app
		next(&b)
		keep := b.keep_alive

		// Drop this request's bytes; anything after belongs to the next one.
		conn_consume(&conn, consumed)
		free_all(context.temp_allocator)

		if !keep {
			return
		}
	}
}

// read_request ensures conn.buf holds one complete HTTP request, parses it, and
// reports how many bytes that request consumed (the caller drops them once the
// response is sent — b.body points into conn.buf until then). On a protocol
// error it returns ok=false plus the status to send (400, or 413 when the body
// exceeds max_body). closed=true means the peer hung up or went idle: stop.
read_request :: proc(
	conn: ^Conn,
	max_body: int,
	allocator := context.temp_allocator,
) -> (
	b: Bifrost,
	consumed: int,
	status: int,
	ok: bool,
	closed: bool,
) {
	// Phase 1: buffer the request + header block, up to the blank line.
	header_end := strings.index(string(conn.buf[:]), "\r\n\r\n")
	for header_end < 0 {
		if len(conn.buf) > MAX_HEADER {
			return {}, 0, 400, false, false
		}
		if !conn_fill(conn) {
			return {}, 0, 0, false, true
		}
		header_end = strings.index(string(conn.buf[:]), "\r\n\r\n")
	}

	head := string(conn.buf[:header_end])

	// Request line: METHOD SP TARGET SP HTTP/1.1
	line_end := strings.index(head, "\r\n")
	if line_end < 0 {
		line_end = len(head)
	}
	parts := strings.split(head[:line_end], " ", allocator)
	if len(parts) < 2 {
		return {}, 0, 400, false, false
	}
	method, method_ok := parse_method(parts[0])
	if !method_ok {
		return {}, 0, 400, false, false
	}
	version := len(parts) >= 3 ? parts[2] : ""

	// Split the target into path (used for routing) and query string. The
	// query reuses the urlencoded decoder, since the syntax is the same.
	path := parts[1]
	query: map[string]string
	if q := strings.index(path, "?"); q >= 0 {
		query = parse_query(path[q + 1:], allocator)
		path = path[:q]
	}

	// Headers run from just past the request line to the blank line.
	req_headers: map[string]string
	if line_end + 2 <= len(head) {
		hdrs, hok := parse_headers(head[line_end + 2:], allocator)
		if !hok {
			return {}, 0, 400, false, false
		}
		req_headers = hdrs
	}

	// Phase 2: body, framed by Content-Length. Absent it (e.g. a GET), there
	// is no body — we must not swallow a pipelined follow-up request.
	body_start := header_end + 4
	content_length := 0
	if cl, has_cl := req_headers["content-length"]; has_cl {
		parsed, pok := strconv.parse_int(strings.trim_space(cl))
		if !pok || parsed < 0 {
			return {}, 0, 400, false, false
		}
		content_length = parsed
	}
	if content_length > max_body {
		return {}, 0, 413, false, false
	}

	for len(conn.buf) - body_start < content_length {
		if !conn_fill(conn) {
			return {}, 0, 0, false, true // truncated body; give up on the socket
		}
	}

	body := conn.buf[body_start:body_start + content_length]

	b = Bifrost {
		method      = method,
		path        = path,
		query       = query,
		req_headers = req_headers,
		body        = body,
		body_text   = string(body),
		client      = conn.socket,
		keep_alive  = keep_alive_wanted(version, req_headers),
	}
	return b, body_start + content_length, 0, true, false
}

// conn_fill pulls one chunk off the socket onto conn.buf. Returns false when
// the peer closed or the idle timeout fired.
conn_fill :: proc(conn: ^Conn) -> bool {
	chunk: [READ_CHUNK]u8
	n, err := net.recv_tcp(conn.socket, chunk[:])
	if err != nil || n == 0 {
		return false
	}
	append(&conn.buf, ..chunk[:n])
	return true
}

// conn_consume drops the first n bytes of conn.buf, sliding the rest down.
conn_consume :: proc(conn: ^Conn, n: int) {
	if n >= len(conn.buf) {
		clear(&conn.buf)
		return
	}
	copy(conn.buf[:], conn.buf[n:])
	resize(&conn.buf, len(conn.buf) - n)
}

// keep_alive_wanted applies the HTTP persistence defaults: 1.1 keeps the
// connection open unless told to close; older versions close unless asked to
// keep alive.
keep_alive_wanted :: proc(version: string, headers: map[string]string) -> bool {
	conn_hdr := ""
	if v, has := headers["connection"]; has {
		conn_hdr = strings.to_lower(strings.trim_space(v), context.temp_allocator)
	}
	if version == "HTTP/1.1" {
		return conn_hdr != "close"
	}
	return conn_hdr == "keep-alive"
}
