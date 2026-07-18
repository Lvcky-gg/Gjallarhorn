package tests

// csrf_test.odin — the CSRF Rune (GH-055): safe methods seed a token and pass;
// unsafe methods need a matching token (header or form field), else 403.
// Run with: odin test ./tests

import "core:fmt"
import "core:testing"
import gh "../gjallarhorn"

// csrf_pass stands in for the rest of the chain: if csrf calls next, the request
// ends 200; if csrf blocks, the status is whatever csrf wrote (403).
csrf_pass :: proc(b: ^gh.Bifrost) {
	gh.text(b, 200, "ok")
}

@(test)
csrf_safe_method_seeds_and_passes :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Get}
	gh.csrf(&b, csrf_pass)
	testing.expect_value(t, b.status, 200) // GET is passed through

	tok, ok := gh.session_get(&b, gh.CSRF_SESSION_KEY)
	testing.expect(t, ok && tok != "", "a GET seeds a CSRF token in the session")
}

@(test)
csrf_unsafe_without_token_blocked :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Post}
	gh.csrf(&b, csrf_pass)
	testing.expect_value(t, b.status, 403) // no session token established -> blocked
}

@(test)
csrf_unsafe_with_header_token_passes :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Post}
	tok := gh.csrf_token(&b) // establish the session token
	b.req_headers = make(map[string]string, context.temp_allocator)
	b.req_headers["x-csrf-token"] = tok
	gh.csrf(&b, csrf_pass)
	testing.expect_value(t, b.status, 200)
}

@(test)
csrf_unsafe_with_wrong_token_blocked :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Post}
	gh.csrf_token(&b) // a real token exists; the request presents a different one
	b.req_headers = make(map[string]string, context.temp_allocator)
	b.req_headers["x-csrf-token"] = "not-the-real-token"
	gh.csrf(&b, csrf_pass)
	testing.expect_value(t, b.status, 403)
}

@(test)
csrf_unsafe_with_form_field_passes :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Post}
	tok := gh.csrf_token(&b)
	b.body_text = fmt.tprintf("csrf_token=%s&other=1", tok)
	gh.csrf(&b, csrf_pass)
	testing.expect_value(t, b.status, 200)
}

@(test)
csrf_token_is_stable_within_request :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Get}
	a := gh.csrf_token(&b)
	c := gh.csrf_token(&b)
	testing.expect(t, a != "", "token is non-empty")
	testing.expect_value(t, a, c) // same token across calls in one request
}
