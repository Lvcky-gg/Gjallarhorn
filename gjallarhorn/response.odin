package gjallarhorn

// response.odin — writing HTTP/1.1 responses to the wire.

import "core:net"
import "core:fmt"
import "core:strings"

write_response :: proc(b: ^Bifrost, status: int, content_type: string, body: string) {
	if b.written {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "HTTP/1.1 %d %s\r\n", status, status_text(status))
	fmt.sbprintf(&sb, "Content-Type: %s\r\n", content_type)
	for key, value in b.headers {
		fmt.sbprintf(&sb, "%s: %s\r\n", key, value)
	}
	fmt.sbprintf(&sb, "Content-Length: %d\r\n", len(body))
	fmt.sbprint(&sb, "Connection: close\r\n\r\n")
	fmt.sbprint(&sb, body)

	net.send_tcp(b.client, transmute([]u8)strings.to_string(sb))
	b.written = true
}

// For early-exit error paths that have no Bifrost yet.
send_raw :: proc(client: net.TCP_Socket, status: int, body: string) {
	resp := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status,
		status_text(status),
		len(body),
		body,
	)
	net.send_tcp(client, transmute([]u8)resp)
}

status_text :: proc(status: int) -> string {
	switch status {
	case 200:
		return "OK"
	case 201:
		return "Created"
	case 204:
		return "No Content"
	case 400:
		return "Bad Request"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 413:
		return "Payload Too Large"
	case 500:
		return "Internal Server Error"
	}
	return "OK"
}
