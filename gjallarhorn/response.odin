package gjallarhorn

// response.odin — writing HTTP/1.1 responses to the wire.

import "core:net"
import "core:fmt"
import "core:strings"

write_response :: proc(b: ^Bifrost, status: int, content_type: string, body: string) {
	if b.written {
		return
	}
	b.status = status
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "HTTP/1.1 %d %s\r\n", status, status_text(status))
	fmt.sbprintf(&sb, "Content-Type: %s\r\n", strip_crlf(content_type))
	for key, value in b.headers {
		fmt.sbprintf(&sb, "%s: %s\r\n", key, value)
	}
	for c in b.cookies {
		fmt.sbprintf(&sb, "Set-Cookie: %s\r\n", c)
	}
	fmt.sbprintf(&sb, "Content-Length: %d\r\n", len(body))
	if b.keep_alive {
		fmt.sbprint(&sb, "Connection: keep-alive\r\n\r\n")
	} else {
		fmt.sbprint(&sb, "Connection: close\r\n\r\n")
	}
	// HEAD (omit_body): the Content-Length above still advertises what GET would
	// return, but no payload follows (RFC 7231 §4.3.2).
	if !b.omit_body {
		fmt.sbprint(&sb, body)
	}

	wire_send(b.client, b.ssl, transmute([]u8)strings.to_string(sb))
	b.written = true
}

// For early-exit error paths that have no Bifrost yet. `ssl` is the connection's
// TLS session (nil for plaintext), so the error still goes out over HTTPS.
send_raw :: proc(client: net.TCP_Socket, ssl: rawptr, status: int, body: string) {
	resp := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status,
		status_text(status),
		len(body),
		body,
	)
	wire_send(client, ssl, transmute([]u8)resp)
}

// on_error registers a handler to render a given error status — a branded 404
// or 500 page, say — replacing the framework's plain-text default. The handler
// is an ordinary Handler; it should write a response (usually `html`/`text` at
// the same status). Covers the errors the framework itself emits: 404 (no
// route), 500 (a handler panicked), 403 (path traversal), and the 401 a Ward
// falls back to. Errors an app writes itself (a rune's 403, bind_json's 400)
// stay under the app's control and aren't rerouted here.
//
//   gh.on_error(&app, 404, my_not_found)
//   gh.on_error(&app, 500, my_server_error)
on_error :: proc(app: ^App, status: int, handler: Handler) {
	if app.errors == nil {
		app.errors = make(map[int]Handler)
	}
	app.errors[status] = handler
}

// emit_error answers `status` with the app's registered handler if it has one,
// else the plain-text default. Nothing is written if a response already went out,
// and if a registered handler declines to write, the default still fills in — so
// an error always gets a body.
emit_error :: proc(b: ^Bifrost, status: int) {
	if b.written {
		return
	}
	if b._app != nil {
		if h, ok := b._app.errors[status]; ok {
			b.status = status // the intended status; the handler may override it
			h(b)
			if b.written {
				return
			}
		}
	}
	write_response(b, status, "text/plain; charset=utf-8", default_error_body(status))
}

// default_error_body is the built-in plain-text body for an error status.
default_error_body :: proc(status: int) -> string {
	switch status {
	case 400:
		return "400 bad request"
	case 401:
		return "401 unauthorized"
	case 403:
		return "403 forbidden"
	case 404:
		return "404 not found"
	case 500:
		return "500 internal server error"
	}
	return fmt.tprintf("%d %s", status, status_text(status))
}

status_text :: proc(status: int) -> string {
	switch status {
	case 200:
		return "OK"
	case 201:
		return "Created"
	case 204:
		return "No Content"
	case 302:
		return "Found"
	case 303:
		return "See Other"
	case 304:
		return "Not Modified"
	case 400:
		return "Bad Request"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 413:
		return "Payload Too Large"
	case 429:
		return "Too Many Requests"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	}
	return "OK"
}
