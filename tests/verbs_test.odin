package tests

// verbs_test.odin — the PATCH/HEAD/OPTIONS route verbs and HEAD's derive-from-GET
// behaviour. PATCH was in the Method enum and the request parser but had no
// registration verb, so a PATCH route was impossible; HEAD had neither a verb nor
// a fallback, so every HEAD 404'd. Run with: odin test ./tests

import "core:net"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

verb_patched :: proc(b: ^gh.Bifrost) {gh.text(b, 200, "patched")}
verb_hello :: proc(b: ^gh.Bifrost) {gh.text(b, 200, "hello")}
verb_optioned :: proc(b: ^gh.Bifrost) {gh.text(b, 200, "optioned")}
// An explicit HEAD handler answers 202 so a test can tell it apart from the
// GET route it would otherwise fall back to.
verb_head_explicit :: proc(b: ^gh.Bifrost) {gh.text(b, 202, "explicit")}

@(test)
patch_route_matches :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.patch(&app, "/p", verb_patched)
	b := dispatch(&app, .Patch, "/p")
	testing.expect_value(t, b.status, 200) // PATCH is now registrable and dispatched
}

@(test)
patch_does_not_match_get_route :: proc(t: ^testing.T) {
	// Method isolation: a PATCH to a GET-only path is a 404, not a mis-dispatch.
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/g", verb_hello)
	b := dispatch(&app, .Patch, "/g")
	testing.expect_value(t, b.status, 404)
}

@(test)
options_route_matches :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.options(&app, "/o", verb_optioned)
	b := dispatch(&app, .Options, "/o")
	testing.expect_value(t, b.status, 200)
}

@(test)
head_falls_back_to_get :: proc(t: ^testing.T) {
	// No HEAD route registered: the matching GET route answers, with the body
	// suppressed (omit_body set).
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/h", verb_hello)
	b := dispatch(&app, .Head, "/h")
	testing.expect_value(t, b.status, 200)
	testing.expect(t, b.omit_body, "HEAD must suppress the response body")
}

@(test)
explicit_head_route_wins :: proc(t: ^testing.T) {
	// An explicit HEAD handler is preferred over the GET fallback.
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/h", verb_hello) // would answer 200
	gh.head(&app, "/h", verb_head_explicit) // answers 202
	b := dispatch(&app, .Head, "/h")
	testing.expect_value(t, b.status, 202)
}

@(test)
head_with_no_route_is_404 :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	b := dispatch(&app, .Head, "/missing")
	testing.expect_value(t, b.status, 404)
}

@(test)
head_sends_headers_without_body :: proc(t: ^testing.T) {
	// The wire proof: a HEAD response carries the GET Content-Length but no bytes
	// after the header terminator.
	server, client, paired := open_pair(t)
	if !paired {
		return
	}
	defer net.close(server)
	defer net.close(client)

	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/h", verb_hello) // body "hello" -> Content-Length: 5

	b := gh.Bifrost {
		method = .Head,
		path   = "/h",
		_app   = &app,
		client = server,
	}
	gh.dispatch_route(&b)
	testing.expect_value(t, b.status, 200)

	buf: [512]u8
	n, _ := net.recv_tcp(client, buf[:])
	resp := string(buf[:n])
	testing.expect(t, strings.contains(resp, "Content-Length: 5"), "HEAD advertises the GET body length")
	idx := strings.index(resp, "\r\n\r\n")
	testing.expect(t, idx >= 0, "response has a header terminator")
	testing.expect_value(t, resp[idx + 4:], "") // nothing follows the headers
}

@(test)
get_sends_body :: proc(t: ^testing.T) {
	// Control for the HEAD test: the same handler over GET does emit the body.
	server, client, paired := open_pair(t)
	if !paired {
		return
	}
	defer net.close(server)
	defer net.close(client)

	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/h", verb_hello)

	b := gh.Bifrost {
		method = .Get,
		path   = "/h",
		_app   = &app,
		client = server,
	}
	gh.dispatch_route(&b)

	buf: [512]u8
	n, _ := net.recv_tcp(client, buf[:])
	resp := string(buf[:n])
	idx := strings.index(resp, "\r\n\r\n")
	testing.expect(t, idx >= 0, "response has a header terminator")
	testing.expect_value(t, resp[idx + 4:], "hello")
}
