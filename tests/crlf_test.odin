package tests

// crlf_test.odin — CRLF injection guard on the response-write path (GH-052).
// set_header / set_cookie must strip CR and LF so a user-influenced value can't
// inject extra header lines or split the response. Run with: odin test ./tests

import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

@(test)
header_value_strips_crlf :: proc(t: ^testing.T) {
	b := gh.Bifrost{}
	gh.set_header(&b, "X-Test", "value\r\nInjected: evil")
	v := b.headers["X-Test"]
	testing.expect(t, strings.index_byte(v, '\r') < 0, "no CR in stored header value")
	testing.expect(t, strings.index_byte(v, '\n') < 0, "no LF in stored header value")
	testing.expect_value(t, v, "valueInjected: evil")
}

@(test)
header_key_strips_crlf :: proc(t: ^testing.T) {
	b := gh.Bifrost{}
	gh.set_header(&b, "X-Bad\r\nInjected", "v")
	_, clean := b.headers["X-BadInjected"]
	testing.expect(t, clean, "CRLF stripped from header key before storage")
	_, raw := b.headers["X-Bad\r\nInjected"]
	testing.expect(t, !raw, "raw CRLF key must not be present")
}

@(test)
header_clean_value_passthrough :: proc(t: ^testing.T) {
	// No control bytes -> value stored unchanged.
	b := gh.Bifrost{}
	gh.set_header(&b, "X-Ok", "plain value")
	testing.expect_value(t, b.headers["X-Ok"], "plain value")
}

@(test)
cookie_strips_crlf :: proc(t: ^testing.T) {
	// An injected value must not produce a second Set-Cookie / split the response.
	b := gh.Bifrost{}
	gh.set_cookie(&b, "sid", "abc\r\nSet-Cookie: admin=1")
	testing.expect_value(t, len(b.cookies), 1)
	line := b.cookies[0]
	testing.expect(t, strings.index_byte(line, '\r') < 0, "no CR in cookie line")
	testing.expect(t, strings.index_byte(line, '\n') < 0, "no LF in cookie line")
}
