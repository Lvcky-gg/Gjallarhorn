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

	if app.postgres.dbname != "" && !app.pool.open {
		if connect(app) {
			fmt.printfln("mimir: connected to postgres %s/%s (pool of %d)", app.postgres.host, app.postgres.dbname, app.pool_size)
		} else {
			fmt.eprintln("mimir: postgres unavailable — migrations will print only")
		}
	}

	migrate(app)

	endpoint := net.Endpoint {
		address = bind_address(app.host),
		port    = app.port,
	}

	// HTTPS (GH-054): when a cert/key pair is configured, build the shared TLS
	// context up front. A misconfiguration here is fatal rather than a silent
	// fall back to plaintext — serving HTTP when HTTPS was asked for is a footgun.
	scheme := "http"
	if app.tls_cert != "" || app.tls_key != "" {
		if app.tls_cert == "" || app.tls_key == "" {
			fmt.eprintln("gjallarhorn: tls_cert and tls_key must both be set for HTTPS")
			return
		}
		when !GJ_TLS {
			fmt.eprintln("gjallarhorn: HTTPS requires a TLS build — rebuild with -define:GJ_TLS=true")
			return
		}
		ctx, ok := tls_server_ctx(app.tls_cert, app.tls_key)
		if !ok {
			return // tls_server_ctx logged the reason
		}
		app.tls_ctx = ctx
		scheme = "https"
	}

	sock, err := net.listen_tcp(endpoint)
	if err != nil {
		fmt.eprintfln("gjallarhorn: listen failed on %v: %v", endpoint, err)
		return
	}
	defer net.close(sock)
	defer if app.tls_ctx != nil {
		tls_ctx_free(app.tls_ctx)
		app.tls_ctx = nil
	}

	fmt.printfln("gjallarhorn: listening on %s://%v", scheme, net.endpoint_to_string(endpoint))

	// One thread per connection. accept_tcp is the only thing the accept loop
	// blocks on; request handling (which may stall on a slow client) is pushed
	// onto a self-cleaning worker thread, so a slow peer never holds the loop.
	// The TLS handshake runs on the worker too, so a slow client cannot stall it.
	for {
		client, _, accept_err := net.accept_tcp(sock)
		if accept_err != nil {
			fmt.eprintfln("gjallarhorn: accept error: %v", accept_err)
			continue
		}
		thread.run_with_poly_data3(app, client, app.tls_ctx, handle_worker)
	}
}

// bind_address resolves the configured host to an address to listen on. An
// empty host means loopback (127.0.0.1); "0.0.0.0" opens all interfaces. An
// unparseable host falls back to loopback with a warning rather than binding
// the world by accident.
bind_address :: proc(host: string) -> net.Address {
	if host == "" {
		return net.IP4_Loopback
	}
	if addr, ok := net.parse_ip4_address(host); ok {
		return addr
	}
	fmt.eprintfln("gjallarhorn: invalid host %q, falling back to loopback", host)
	return net.IP4_Loopback
}

// handle_worker is the per-connection thread body. Each worker runs with its
// own context (and thus its own thread-local temp allocator), so the per-request
// free_all inside handle_connection only ever reclaims this worker's arena —
// safe under concurrency.
handle_worker :: proc(app: ^App, client: net.TCP_Socket, tls_ctx: rawptr) {
	// An idle/slow socket must not pin a worker forever; the timeout applies to
	// the TLS handshake below as well as to per-request reads.
	net.set_option(net.Any_Socket(client), .Receive_Timeout, IDLE_TIMEOUT)

	// HTTPS: complete the server-side handshake before reading any HTTP. On
	// failure (non-TLS client, bad handshake, timeout) drop the connection.
	ssl: rawptr
	if tls_ctx != nil {
		ok: bool
		ssl, ok = tls_server_accept(tls_ctx, client)
		if !ok {
			net.close(client)
			free_all(context.temp_allocator)
			return
		}
	}

	handle_connection(app, client, ssl)

	if ssl != nil {
		tls_free(ssl)
	}
	net.close(client)
	free_all(context.temp_allocator)
}

// wire_send writes the whole buffer to the connection, through TLS when ssl is
// set and over the raw socket otherwise. In a non-TLS build ssl is always nil,
// so the tls_send branch is dead (and stubbed).
wire_send :: proc(sock: net.TCP_Socket, ssl: rawptr, data: []u8) -> bool {
	if ssl != nil {
		return tls_send(ssl, data)
	}
	_, err := net.send_tcp(sock, data)
	return err == nil
}

// wire_recv reads up to len(dst) bytes, through TLS when ssl is set.
wire_recv :: proc(sock: net.TCP_Socket, ssl: rawptr, dst: []u8) -> (int, bool) {
	if ssl != nil {
		return tls_recv(ssl, dst)
	}
	n, err := net.recv_tcp(sock, dst)
	if err != nil {
		return 0, false
	}
	return n, true
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
	ssl:    rawptr, // TLS session for this connection; nil for plaintext (GH-054)
	buf:    [dynamic]u8,
}

handle_connection :: proc(app: ^App, client: net.TCP_Socket, ssl: rawptr) {
	conn := Conn {
		socket = client,
		ssl    = ssl,
		buf    = make([dynamic]u8),
	}
	defer delete_dynamic_array(conn.buf) // builtin; package `delete` is the route verb

	for {
		b, consumed, status, ok, closed := read_request(&conn, app.max_body)
		if closed {
			return // idle timeout, EOF, or a truncated request
		}
		if !ok {
			send_raw(client, conn.ssl, status, fmt.tprintf("%d %s", status, status_text(status)))
			return
		}

		b._app = app
		run_guarded(&b) // panic recovery boundary (GH-011)
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
		ssl         = conn.ssl,
		keep_alive  = keep_alive_wanted(version, req_headers),
	}
	return b, body_start + content_length, 0, true, false
}

// conn_fill pulls one chunk off the socket onto conn.buf. Returns false when
// the peer closed or the idle timeout fired.
conn_fill :: proc(conn: ^Conn) -> bool {
	chunk: [READ_CHUNK]u8
	n, ok := wire_recv(conn.socket, conn.ssl, chunk[:])
	if !ok || n == 0 {
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
