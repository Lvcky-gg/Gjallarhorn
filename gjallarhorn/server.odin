package gjallarhorn

// server.odin — the socket loop: listen, accept, read, parse the request line,
// then hand the Bifrost to the rune chain.

import "core:net"
import "core:fmt"
import "core:strings"

run :: proc(app: ^App) {
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

// Phase 1 security checkpoint: a fixed read buffer bounds the request line +
// headers. Slowloris/read timeouts are a TODO once we move past blocking accept.
MAX_REQUEST :: 8192

handle_connection :: proc(app: ^App, client: net.TCP_Socket) {
	buf: [MAX_REQUEST]u8
	n, recv_err := net.recv_tcp(client, buf[:])
	if recv_err != nil || n == 0 {
		return
	}
	data := string(buf[:n])

	// Request line: METHOD SP TARGET SP HTTP/1.1
	line_end := strings.index(data, "\r\n")
	if line_end < 0 {
		line_end = len(data)
	}
	request_line := data[:line_end]

	parts := strings.split(request_line, " ", context.temp_allocator)
	if len(parts) < 2 {
		send_raw(client, 400, "400 bad request")
		return
	}

	method, method_ok := parse_method(parts[0])
	if !method_ok {
		send_raw(client, 400, "400 bad request")
		return
	}

	// Strip query string; routing is on path only for now.
	path := parts[1]
	if q := strings.index(path, "?"); q >= 0 {
		path = path[:q]
	}

	b := Bifrost {
		method = method,
		path   = path,
		client = client,
		_app   = app,
	}
	next(&b)
}
