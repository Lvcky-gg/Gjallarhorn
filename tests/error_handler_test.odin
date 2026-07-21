package tests

// error_handler_test.odin — custom error pages via on_error (response.odin).
// The framework's default 404/401/403/500 can be replaced per-app; a registered
// handler that declines to write still falls back to the default, and a 500
// handler that panics falls back rather than aborting the worker. Run with:
// odin test ./tests

import "core:net"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

err_custom_404 :: proc(b: ^gh.Bifrost) {gh.html(b, 404, "<h1>lost in Niflheim</h1>")}
err_custom_401 :: proc(b: ^gh.Bifrost) {gh.text(b, 401, "the ward turns you away")}
err_custom_403 :: proc(b: ^gh.Bifrost) {gh.text(b, 403, "no path here")}
err_custom_500 :: proc(b: ^gh.Bifrost) {gh.text(b, 500, "the well ran dry")}
err_noop :: proc(b: ^gh.Bifrost) {} // declines to write -> default must fill in
err_boom_500 :: proc(b: ^gh.Bifrost) {panic("the 500 handler itself explodes")}
err_plain_ok :: proc(b: ^gh.Bifrost) {gh.text(b, 200, "ok")}

// dispatch_resp runs one request through dispatch_route against a live socket and
// returns the raw response, so the body (default vs custom) is observable.
dispatch_resp :: proc(t: ^testing.T, app: ^gh.App, method: gh.Method, path: string) -> string {
	server, client, ok := open_pair(t)
	if !ok {
		return ""
	}
	defer net.close(server)
	defer net.close(client)
	b := gh.Bifrost {
		method = method,
		path   = path,
		client = server,
		_app   = app,
	}
	gh.dispatch_route(&b)
	buf: [4096]u8
	n, _ := net.recv_tcp(client, buf[:])
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

body_after_headers :: proc(resp: string) -> string {
	if i := strings.index(resp, "\r\n\r\n"); i >= 0 {
		return resp[i + 4:]
	}
	return ""
}

@(test)
error_default_404 :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	resp := dispatch_resp(t, &app, .Get, "/missing")
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 404"), "404 status")
	testing.expect_value(t, body_after_headers(resp), "404 not found") // built-in default
}

@(test)
error_custom_404 :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.on_error(&app, 404, err_custom_404)
	resp := dispatch_resp(t, &app, .Get, "/missing")
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 404"), "still 404")
	testing.expect(t, strings.contains(resp, "text/html"), "custom handler set its own type")
	testing.expect_value(t, body_after_headers(resp), "<h1>lost in Niflheim</h1>")
}

@(test)
error_custom_401_via_ward :: proc(t: ^testing.T) {
	// A Ward that denies without writing falls back to emit_error(401).
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/guarded", err_plain_ok, ward_deny_silent)
	gh.on_error(&app, 401, err_custom_401)
	resp := dispatch_resp(t, &app, .Get, "/guarded")
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 401"), "401")
	testing.expect_value(t, body_after_headers(resp), "the ward turns you away")
}

@(test)
error_custom_403_via_traversal :: proc(t: ^testing.T) {
	dir := fixture_dir(t, {{"ok.txt", "hi"}})
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.on_error(&app, 403, err_custom_403)

	server, client, ok := open_pair(t)
	if !ok {return}
	defer net.close(server)
	defer net.close(client)
	b := gh.Bifrost {
		method = .Get,
		path   = "/s/../../etc/passwd", // escapes the mount root
		client = server,
		_app   = &app,
	}
	gh.serve_static(&b, gh.Static_Mount{url_prefix = "/s", dir = dir})
	buf: [1024]u8
	n, _ := net.recv_tcp(client, buf[:])
	resp := string(buf[:n])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 403"), "traversal -> 403")
	testing.expect_value(t, body_after_headers(resp), "no path here")
}

@(test)
error_handler_declining_falls_back :: proc(t: ^testing.T) {
	// A registered handler that writes nothing must still yield the default body.
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.on_error(&app, 404, err_noop)
	resp := dispatch_resp(t, &app, .Get, "/missing")
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 404"), "404")
	testing.expect_value(t, body_after_headers(resp), "404 not found")
}

@(test)
error_custom_500_on_panic :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/boom", boom_handler) // panics (defined in recover_test.odin)
	gh.on_error(&app, 500, err_custom_500)

	server, client, ok := open_pair(t)
	if !ok {return}
	defer net.close(server)
	defer net.close(client)
	b := gh.Bifrost {
		method = .Get,
		path   = "/boom",
		client = server,
		_app   = &app,
	}
	gh.run_guarded(&b)
	testing.expect(t, b.written, "recovery wrote a response")
	buf: [1024]u8
	n, _ := net.recv_tcp(client, buf[:])
	resp := string(buf[:n])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 500"), "500")
	testing.expect_value(t, body_after_headers(resp), "the well ran dry")
}

@(test)
error_500_handler_that_panics_falls_back :: proc(t: ^testing.T) {
	// The re-arm safety: if the custom 500 handler panics too, we must fall back
	// to the plain default instead of aborting the worker.
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/boom", boom_handler)
	gh.on_error(&app, 500, err_boom_500)

	server, client, ok := open_pair(t)
	if !ok {return}
	defer net.close(server)
	defer net.close(client)
	b := gh.Bifrost {
		method = .Get,
		path   = "/boom",
		client = server,
		_app   = &app,
	}
	gh.run_guarded(&b)
	buf: [1024]u8
	n, _ := net.recv_tcp(client, buf[:])
	resp := string(buf[:n])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 500"), "still a 500")
	testing.expect_value(t, body_after_headers(resp), "500 internal server error") // the default
}
