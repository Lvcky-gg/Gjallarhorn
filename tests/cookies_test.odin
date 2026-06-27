package tests

// cookies_test.odin — cookie reader/writer round-trip (GH-050). Run with:
//   odin test ./tests

import "core:fmt"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

@(test)
cookie_read :: proc(t: ^testing.T) {
	h, _ := gh.parse_headers("Cookie: session=abc; theme=dark", context.temp_allocator)
	b := gh.Bifrost {
		req_headers = h,
	}

	v, ok := gh.cookie(&b, "session")
	testing.expect(t, ok, "session cookie should be present")
	testing.expect_value(t, v, "abc")

	v2, ok2 := gh.cookie(&b, "theme")
	testing.expect(t, ok2)
	testing.expect_value(t, v2, "dark")

	_, miss := gh.cookie(&b, "absent")
	testing.expect(t, !miss, "absent cookie reports not found")
}

@(test)
cookie_read_no_header :: proc(t: ^testing.T) {
	b := gh.Bifrost{}
	_, ok := gh.cookie(&b, "anything")
	testing.expect(t, !ok, "no Cookie header -> not found")
}

@(test)
cookie_write_all_attrs :: proc(t: ^testing.T) {
	b := gh.Bifrost{}
	gh.set_cookie(
		&b,
		"session",
		"abc",
		gh.Cookie_Options{max_age = 3600, same_site = .Lax, http_only = true, secure = true},
	)
	testing.expect_value(t, len(b.cookies), 1)
	testing.expect_value(t, b.cookies[0], "session=abc; Path=/; Max-Age=3600; SameSite=Lax; HttpOnly; Secure")
}

@(test)
cookie_write_defaults :: proc(t: ^testing.T) {
	// Zero options -> a plain session cookie scoped to "/".
	b := gh.Bifrost{}
	gh.set_cookie(&b, "x", "1")
	testing.expect_value(t, b.cookies[0], "x=1; Path=/")
}

@(test)
cookie_write_path_domain :: proc(t: ^testing.T) {
	b := gh.Bifrost{}
	gh.set_cookie(&b, "x", "1", gh.Cookie_Options{path = "/app", domain = "example.com"})
	testing.expect_value(t, b.cookies[0], "x=1; Path=/app; Domain=example.com")
}

@(test)
cookie_delete_is_max_age_zero :: proc(t: ^testing.T) {
	b := gh.Bifrost{}
	gh.set_cookie(&b, "sid", "", gh.Cookie_Options{max_age = 0})
	testing.expect_value(t, b.cookies[0], "sid=; Path=/; Max-Age=0")
}

@(test)
cookie_multiple :: proc(t: ^testing.T) {
	// Each set_cookie is its own header line, so multiple cookies coexist.
	b := gh.Bifrost{}
	gh.set_cookie(&b, "a", "1")
	gh.set_cookie(&b, "b", "2")
	testing.expect_value(t, len(b.cookies), 2)
	testing.expect_value(t, b.cookies[0], "a=1; Path=/")
	testing.expect_value(t, b.cookies[1], "b=2; Path=/")
}

@(test)
cookie_round_trip :: proc(t: ^testing.T) {
	// Write a cookie, then feed the name=value the browser would echo back into
	// a fresh request and read it out again.
	out := gh.Bifrost{}
	gh.set_cookie(&out, "sid", "xyz789", gh.Cookie_Options{http_only = true})

	name_value := strings.split(out.cookies[0], ";", context.temp_allocator)[0]
	h, _ := gh.parse_headers(fmt.tprintf("Cookie: %s", name_value), context.temp_allocator)
	in_req := gh.Bifrost {
		req_headers = h,
	}

	v, ok := gh.cookie(&in_req, "sid")
	testing.expect(t, ok)
	testing.expect_value(t, v, "xyz789")
}
