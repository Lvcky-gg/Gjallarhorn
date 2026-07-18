package gjallarhorn

// server.odin — the socket loop: listen, accept, read, parse the request line,
// then hand the Bifrost to the rune chain. Connections are kept alive and
// reused across requests per RFC 7230 (see handle_connection).

import "core:c/libc"
import "core:net"
import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"

run :: proc(app: ^App) {

	// Fail closed on the insecure default session secret. Session cookies are
	// HMAC-signed with app.secret; an empty or default key is public knowledge,
	// so any client could forge a session. In a debug build we warn and let the
	// operator keep moving; in a release build we refuse to start (GH-051).
	if app.secret == "" || app.secret == DEFAULT_SECRET {
		when ODIN_DEBUG {
			logf(.Warn, "session secret is the insecure default; set Config.secret before shipping (release builds refuse to start)")
		} else {
			logf(.Error, "refusing to start: Config.secret is unset or the insecure default; sessions would be forgeable. Set Config.secret to a strong random value.")
			return
		}
	}

	pretty := stream_color(.Info)
	if app.postgres.dbname != "" && !app.pool.open {
		if connect(app) {
			fmt.printfln(
				"%s  connected to postgres %s/%s (pool of %d)",
				paint(pretty, "\e[1;34m", "mimir"),
				app.postgres.host,
				app.postgres.dbname,
				app.pool_size,
			)
		} else {
			logft(.Warn, "mimir", "postgres unavailable — migrations will print only")
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
			logft(.Error, "gjallarhorn", "tls_cert and tls_key must both be set for HTTPS")
			return
		}
		when !GJ_TLS {
			logft(.Error, "gjallarhorn", "HTTPS requires a TLS build — rebuild with -define:GJ_TLS=true")
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
		logft(.Error, "gjallarhorn", "listen failed on %v: %v", endpoint, err)
		return
	}
	defer net.close(sock)
	defer if app.tls_ctx != nil {
		tls_ctx_free(app.tls_ctx)
		app.tls_ctx = nil
	}

	url := fmt.tprintf("%s://%v", scheme, net.endpoint_to_string(endpoint))
	fmt.printfln(
		"%s %s  listening on %s",
		paint(pretty, "\e[1;35m", "▲"),
		paint(pretty, "\e[1m", "gjallarhorn"),
		paint(pretty, "\e[1;36m", url),
	)

	// Graceful shutdown + never dying on a broken pipe. SIGINT/SIGTERM flip the
	// shutdown flag (the workers below drain and exit); SIGPIPE is ignored so a
	// client that hangs up mid-response makes send() return an error we handle,
	// not a signal that kills the process.
	install_signal_handlers()

	// Bounded worker pool. A fixed set of threads each accept on the shared
	// listening socket — the kernel hands each new connection to exactly one — so
	// concurrency is capped at app.workers instead of spawning an unbounded thread
	// per connection (a cheap resource-exhaustion DoS). Excess connections wait in
	// the kernel's accept backlog. A short accept timeout lets each worker notice a
	// shutdown request between connections and exit.
	net.set_option(net.Any_Socket(sock), .Receive_Timeout, ACCEPT_POLL)

	workers := make([]^thread.Thread, app.workers)
	for i in 0 ..< app.workers {
		workers[i] = thread.create_and_start_with_poly_data2(
			app,
			sock,
			accept_worker,
			self_cleanup = false,
		)
	}

	// Park the main thread until a signal requests shutdown.
	for !sync.atomic_load(&_shutting_down) {
		time.sleep(200 * time.Millisecond)
	}

	// Drain: workers stop taking new connections and finish in-flight requests,
	// then exit; join them so shutdown waits for the drain (bounded by IDLE_TIMEOUT
	// for a worker parked on a slow keep-alive read). The deferred socket/TLS
	// teardown then runs as run() returns.
	logft(.Info, "gjallarhorn", "shutting down: draining %d workers", app.workers)
	for w in workers {
		thread.join(w)
		thread.destroy(w)
	}
	delete_slice(workers) // builtin; package `delete` is the route verb
	disconnect(app) // close the DB connection pool
	logft(.Info, "gjallarhorn", "shut down cleanly")
}

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------

// _shutting_down is flipped by the signal handler and read (atomically) by the
// accept workers and the keep-alive loop. Package-global because a C signal
// handler can carry no context.
@(private)
_shutting_down: bool

// SIGPIPE is not exported by core:c/libc; it's 13 on Linux (the target here).
@(private)
SIGPIPE :: 13

// ACCEPT_POLL bounds how long a worker blocks in accept before looping to
// re-check the shutdown flag — so Ctrl-C is noticed within this window.
ACCEPT_POLL :: 300 * time.Millisecond

_handle_shutdown_signal :: proc "c" (sig: i32) {
	sync.atomic_store(&_shutting_down, true)
}

install_signal_handlers :: proc() {
	libc.signal(libc.SIGINT, _handle_shutdown_signal)
	libc.signal(libc.SIGTERM, _handle_shutdown_signal)
	ignore := transmute(proc "c" (i32))libc.SIG_IGN
	libc.signal(SIGPIPE, ignore)
}

// accept_worker is one thread of the pool: accept a connection off the shared
// listening socket and serve it to completion, then take the next — until a
// shutdown is requested. The accept timeout (ACCEPT_POLL) makes the flag check
// responsive even with no traffic.
accept_worker :: proc(app: ^App, sock: net.TCP_Socket) {
	for !sync.atomic_load(&_shutting_down) {
		client, _, accept_err := net.accept_tcp(sock)
		if accept_err != nil {
			#partial switch accept_err {
			case .Would_Block, .Interrupted:
			// accept timed out (poll tick) or was interrupted — loop and re-check.
			case:
				logft(.Error, "gjallarhorn", "accept error: %v", accept_err)
			}
			continue
		}
		handle_worker(app, client, app.tls_ctx)
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
	logft(.Warn, "gjallarhorn", "invalid host %q, falling back to loopback", host)
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
		// Graceful drain: once shutdown is requested, finish the in-flight request
		// (already done above) but take no further request on this kept-alive
		// connection, so the worker returns promptly instead of parking on the next
		// read up to the idle timeout.
		if sync.atomic_load(&_shutting_down) {
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

	// Phase 2: body. Framed by Transfer-Encoding: chunked when present, else by
	// Content-Length. Absent both (e.g. a GET), there is no body — we must not
	// swallow a pipelined follow-up request.
	body_start := header_end + 4
	te, has_te := req_headers["transfer-encoding"]
	_, has_cl := req_headers["content-length"]

	if has_te {
		// Request-smuggling defense (RFC 7230 §3.3.3): a message carrying BOTH
		// Transfer-Encoding and Content-Length is ambiguous — a front-end and
		// back-end can disagree on the body boundary. Reject rather than guess.
		if has_cl {
			return {}, 0, 400, false, false
		}
		// We implement `chunked` only. Any other coding (or chunked bundled with
		// another, which we can't decode) is refused, never mis-framed as smuggling.
		if !body_is_chunked(te) {
			return {}, 0, 501, false, false
		}
		body, end, st, bok, bclosed := read_chunked_body(conn, body_start, max_body, allocator)
		if bclosed {
			return {}, 0, 0, false, true
		}
		if !bok {
			return {}, 0, st, false, false
		}
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
		return b, end, 0, true, false
	}

	content_length := 0
	if cl, ok := req_headers["content-length"]; ok {
		// Content-Length must be a pure decimal run (RFC 7230 §3.3.2, 1*DIGIT).
		// strconv.parse_int is far more permissive — it accepts 0x/0o/0b prefixes,
		// `_` digit separators, and a leading `+` — so an intermediary and this
		// server could frame the body differently (request smuggling). Validate
		// the digits ourselves before trusting the value.
		digits := strings.trim_space(cl)
		if !is_decimal(digits) {
			return {}, 0, 400, false, false
		}
		parsed, pok := strconv.parse_int(digits)
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

// is_decimal reports whether `s` is a non-empty run of ASCII digits only — the
// strict `1*DIGIT` a Content-Length must be, with none of strconv.parse_int's
// prefix/underscore/sign leniency that would open a framing discrepancy.
is_decimal :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// is_hex reports whether `s` is a non-empty run of ASCII hex digits only — the
// strict `1*HEXDIG` a chunk size must be (extensions already stripped upstream).
is_hex :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

// body_is_chunked reports whether a Transfer-Encoding header names `chunked` as
// its sole coding. We deliberately accept only a lone `chunked` (case-insensitive)
// — a stack like "gzip, chunked" needs codings we don't implement, so we refuse
// it rather than under-decode and desync the stream.
body_is_chunked :: proc(te: string) -> bool {
	return strings.to_lower(strings.trim_space(te), context.temp_allocator) == "chunked"
}

// CHUNK_LINE_MAX caps a chunk-size line (hex size + any extensions). A line with
// no CRLF inside this bound is treated as malformed, so a peer can't grow the
// read buffer without end.
CHUNK_LINE_MAX :: 1024

// read_chunked_body decodes a Transfer-Encoding: chunked request body starting at
// conn.buf[body_start], filling from the socket as needed. It returns the
// reassembled body (in `allocator`) and `end`, the absolute index in conn.buf
// just past the terminating chunk — so the caller drops exactly the framing bytes
// and a pipelined next request stays intact. On a malformed body it returns
// ok=false with a status; closed=true means the peer hung up mid-body. The
// decoded size is capped at max_body (413) before each chunk is buffered, so a
// hostile stream can't exhaust memory (GH-0xx request-smuggling hardening).
read_chunked_body :: proc(
	conn: ^Conn,
	body_start, max_body: int,
	allocator := context.temp_allocator,
) -> (
	body: []u8,
	end: int,
	status: int,
	ok: bool,
	closed: bool,
) {
	decoded := make([dynamic]u8, 0, 256, allocator)
	pos := body_start
	for {
		// chunk-size line: <hex>[;ext]CRLF
		crlf, lok, lclosed := find_crlf_fill(conn, pos, CHUNK_LINE_MAX)
		if lclosed {
			return {}, 0, 0, false, true
		}
		if !lok {
			return {}, 0, 400, false, false
		}
		line := string(conn.buf[pos:crlf])
		if sc := strings.index_byte(line, ';'); sc >= 0 {
			line = line[:sc] // drop chunk extensions
		}
		// The chunk size is a pure hex run (RFC 7230 §4.1, 1*HEXDIG). Explicit
		// base 16 already blocks a 0x prefix, but parse_int still accepts `_`
		// separators and a leading `+`, which a conforming intermediary rejects —
		// the same framing-discrepancy class as Content-Length above.
		hexdigits := strings.trim_space(line)
		if !is_hex(hexdigits) {
			return {}, 0, 400, false, false
		}
		size, sok := strconv.parse_int(hexdigits, 16)
		if !sok || size < 0 {
			return {}, 0, 400, false, false
		}
		pos = crlf + 2 // past the CRLF after the size line

		if size == 0 {
			// Last chunk. Consume any trailer header lines up to the blank line
			// that ends the message.
			tcrlf, tok, tclosed := find_crlf_fill(conn, pos, MAX_HEADER)
			if tclosed {
				return {}, 0, 0, false, true
			}
			if !tok {
				return {}, 0, 400, false, false
			}
			for tcrlf != pos { // non-empty line => a trailer; skip it
				pos = tcrlf + 2
				tcrlf, tok, tclosed = find_crlf_fill(conn, pos, MAX_HEADER)
				if tclosed {
					return {}, 0, 0, false, true
				}
				if !tok {
					return {}, 0, 400, false, false
				}
			}
			return decoded[:], tcrlf + 2, 0, true, false // past the final blank line
		}

		// Reject before buffering the chunk, so a huge declared size can't force
		// an oversized read.
		if len(decoded) + size > max_body {
			return {}, 0, 413, false, false
		}
		// Need `size` data bytes plus the trailing CRLF.
		for len(conn.buf) < pos + size + 2 {
			if !conn_fill(conn) {
				return {}, 0, 0, false, true
			}
		}
		if string(conn.buf[pos + size:pos + size + 2]) != "\r\n" {
			return {}, 0, 400, false, false // data not CRLF-terminated
		}
		append(&decoded, ..conn.buf[pos:pos + size])
		pos = pos + size + 2
	}
}

// find_crlf_fill ensures conn.buf holds a CRLF at or after `from`, pulling more
// bytes as needed, and returns that CRLF's index. `limit` bounds how far past
// `from` we scan without a terminator, so a line that never ends can't grow the
// buffer unbounded (returns ok=false past the limit). closed=true means the peer
// hung up first.
find_crlf_fill :: proc(conn: ^Conn, from, limit: int) -> (idx: int, ok: bool, closed: bool) {
	for {
		if i := strings.index(string(conn.buf[from:]), "\r\n"); i >= 0 {
			return from + i, true, false
		}
		if len(conn.buf) - from > limit {
			return 0, false, false
		}
		if !conn_fill(conn) {
			return 0, false, true
		}
	}
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
