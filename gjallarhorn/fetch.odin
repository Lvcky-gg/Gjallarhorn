package gjallarhorn

// fetch.odin — a small outbound HTTP(S) client, so handlers (and any code) can
// call other APIs. It reuses the same pieces as the server: net for the socket,
// the TLS client path for https (tls.odin — https needs a -define:GJ_TLS=true
// build, exactly like the DB's TLS), wire_send/wire_recv (which already abstract
// plaintext vs TLS), and parse_headers for the response.
//
//   res, ok := gh.fetch("https://api.example.com/v1/things")
//   if ok && res.status == 200 {
//       payload: My_Type
//       json.unmarshal(res.body_bytes, &payload)
//   }
//
//   // with a JSON body:
//   res, ok := gh.fetch_json("POST", "https://api.example.com/things", My_Type{...})
//
// It sends `Connection: close` and reads to EOF, de-chunking a chunked response.
// Redirects are returned, not followed (read res.headers["location"]).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

// FETCH_TIMEOUT bounds how long a read may stall before fetch gives up.
FETCH_TIMEOUT :: 30 * time.Second

// Fetch_Request shapes an outbound call. The zero value is a plain GET.
Fetch_Request :: struct {
	method:               string, // "GET" if empty
	headers:              map[string]string, // extra request headers
	body:                 string, // request body (sets Content-Length)
	timeout:              time.Duration, // 0 -> FETCH_TIMEOUT
	insecure_skip_verify: bool, // skip TLS cert/hostname verification (https only)
}

// Fetch_Response is what came back. `headers` keys are lower-cased (as the server
// parser stores them), so `res.headers["content-type"]` works regardless of case.
Fetch_Response :: struct {
	status:     int,
	headers:    map[string]string,
	body:       string,
	body_bytes: []u8,
}

// fetch performs one HTTP(S) request and returns the response. ok is false on a
// transport failure (DNS, connect, TLS, or no parseable response) — a 4xx/5xx is
// still ok=true with the status set.
fetch :: proc(
	url: string,
	req := Fetch_Request{},
	allocator := context.temp_allocator,
) -> (
	res: Fetch_Response,
	ok: bool,
) {
	scheme, host, port, path, uok := parse_fetch_url(url)
	if !uok {
		logft(.Warn, "fetch", "bad url %q", url)
		return {}, false
	}
	if scheme == "https" && !GJ_TLS {
		logft(.Error, "fetch", "https needs a TLS build — rebuild with -define:GJ_TLS=true")
		return {}, false
	}

	ep, rerr := net.resolve_ip4(fmt.tprintf("%s:%d", host, port))
	if rerr != nil {
		logft(.Warn, "fetch", "cannot resolve %s: %v", host, rerr)
		return {}, false
	}
	sock, derr := net.dial_tcp(ep)
	if derr != nil {
		logft(.Warn, "fetch", "dial %s:%d failed: %v", host, port, derr)
		return {}, false
	}
	defer net.close(sock)

	timeout := req.timeout > 0 ? req.timeout : FETCH_TIMEOUT
	net.set_option(net.Any_Socket(sock), .Receive_Timeout, timeout)

	// https: upgrade the socket. On any TLS failure, bail.
	ssl: rawptr
	if scheme == "https" {
		s, tok := tls_client_connect(sock, host, !req.insecure_skip_verify)
		if !tok {
			return {}, false // tls_client_connect logged why
		}
		ssl = s
		defer tls_free(ssl)
	}

	if !wire_send(sock, ssl, transmute([]u8)build_fetch_request(scheme, host, port, path, req, allocator)) {
		return {}, false
	}

	raw, rok := read_to_eof(sock, ssl, allocator)
	if !rok {
		return {}, false
	}
	return parse_fetch_response(raw, allocator)
}

// fetch_json is fetch with a JSON body: it marshals `payload`, sets
// Content-Type: application/json, and sends it with `method`.
fetch_json :: proc(
	method, url: string,
	payload: any,
	req := Fetch_Request{},
	allocator := context.temp_allocator,
) -> (
	Fetch_Response,
	bool,
) {
	data, merr := json.marshal(payload, {}, allocator)
	if merr != nil {
		return {}, false
	}
	r := req
	r.method = method
	r.body = string(data)
	if r.headers == nil {
		r.headers = make(map[string]string, allocator)
	}
	r.headers["Content-Type"] = "application/json"
	return fetch(url, r, allocator)
}

// ---------------------------------------------------------------------------
// internals
// ---------------------------------------------------------------------------

@(private)
build_fetch_request :: proc(
	scheme, host: string,
	port: int,
	path: string,
	req: Fetch_Request,
	allocator: runtime.Allocator,
) -> string {
	b := strings.builder_make(allocator)
	method := req.method == "" ? "GET" : req.method
	// Host omits the default port, per convention.
	host_hdr := host
	if !(scheme == "http" && port == 80) && !(scheme == "https" && port == 443) {
		host_hdr = fmt.tprintf("%s:%d", host, port)
	}
	fmt.sbprintf(&b, "%s %s HTTP/1.1\r\n", method, path)
	fmt.sbprintf(&b, "Host: %s\r\n", host_hdr)
	fmt.sbprint(&b, "Connection: close\r\n")

	have_ua, have_accept := false, false
	for k, v in req.headers {
		lk := strings.to_lower(k, allocator)
		if lk == "user-agent" {have_ua = true}
		if lk == "accept" {have_accept = true}
		// strip_crlf so a header value can't inject extra lines (same guard as set_header).
		fmt.sbprintf(&b, "%s: %s\r\n", strip_crlf(k), strip_crlf(v))
	}
	if !have_ua {fmt.sbprint(&b, "User-Agent: gjallarhorn\r\n")}
	if !have_accept {fmt.sbprint(&b, "Accept: */*\r\n")}
	if len(req.body) > 0 {
		fmt.sbprintf(&b, "Content-Length: %d\r\n", len(req.body))
	}
	fmt.sbprint(&b, "\r\n")
	fmt.sbprint(&b, req.body)
	return strings.to_string(b)
}

// read_to_eof pulls the whole response off the socket. We send Connection: close,
// so the server closes when done and the read ends at EOF.
@(private)
read_to_eof :: proc(sock: net.TCP_Socket, ssl: rawptr, allocator: runtime.Allocator) -> ([]u8, bool) {
	buf := make([dynamic]u8, allocator)
	chunk: [8192]u8
	for {
		n, rok := wire_recv(sock, ssl, chunk[:])
		if n > 0 {
			append(&buf, ..chunk[:n])
		}
		if !rok || n == 0 {
			break // EOF (or a timeout, after which we return what we have)
		}
	}
	if len(buf) == 0 {
		return nil, false
	}
	return buf[:], true
}

@(private)
parse_fetch_response :: proc(raw: []u8, allocator: runtime.Allocator) -> (res: Fetch_Response, ok: bool) {
	head_end := strings.index(string(raw), "\r\n\r\n")
	if head_end < 0 {
		return {}, false
	}
	head := string(raw[:head_end])
	body := raw[head_end + 4:]

	// Status line: HTTP/1.1 <code> <reason>
	line_end := strings.index(head, "\r\n")
	status_line := line_end < 0 ? head : head[:line_end]
	parts := strings.split(status_line, " ", allocator)
	if len(parts) < 2 {
		return {}, false
	}
	res.status, _ = strconv.parse_int(parts[1])

	if line_end >= 0 {
		hdrs, hok := parse_headers(head[line_end + 2:], allocator)
		if hok {
			res.headers = hdrs
		}
	}

	// A chunked response still needs de-framing (we read it whole).
	if te, has := res.headers["transfer-encoding"]; has && strings.contains(strings.to_lower(te, allocator), "chunked") {
		body = dechunk(body, allocator)
	}
	res.body_bytes = body
	res.body = string(body)
	return res, true
}

// dechunk reassembles a chunked body already held in memory: <hex-size>CRLF
// <data>CRLF … to a 0-size chunk. Malformed input yields what was decoded so far.
@(private)
dechunk :: proc(src: []u8, allocator: runtime.Allocator) -> []u8 {
	out := make([dynamic]u8, allocator)
	pos := 0
	for pos < len(src) {
		nl := strings.index(string(src[pos:]), "\r\n")
		if nl < 0 {
			break
		}
		size_line := string(src[pos:pos + nl])
		if sc := strings.index_byte(size_line, ';'); sc >= 0 {
			size_line = size_line[:sc] // drop extensions
		}
		size, sok := strconv.parse_int(strings.trim_space(size_line), 16)
		if !sok || size <= 0 {
			break // 0 chunk or garbage — done
		}
		start := pos + nl + 2
		if start + size > len(src) {
			break
		}
		append(&out, ..src[start:start + size])
		pos = start + size + 2 // past the data and its trailing CRLF
	}
	return out[:]
}

// parse_fetch_url splits an http(s) URL into scheme, host, port, and path
// (path keeps the query). Defaults: port 80/443 by scheme, path "/".
parse_fetch_url :: proc(url: string) -> (scheme, host: string, port: int, path: string, ok: bool) {
	s := url
	scheme = "http"
	if strings.has_prefix(s, "https://") {
		scheme = "https";s = s[8:];port = 443
	} else if strings.has_prefix(s, "http://") {
		s = s[7:];port = 80
	} else {
		return "", "", 0, "", false
	}

	path = "/"
	if slash := strings.index_byte(s, '/'); slash >= 0 {
		path = s[slash:]
		s = s[:slash]
	}
	host = s
	if colon := strings.index_byte(s, ':'); colon >= 0 {
		host = s[:colon]
		if p, pok := strconv.parse_int(s[colon + 1:]); pok {
			port = p
		}
	}
	return scheme, host, port, path, host != "" && port > 0
}
