package tests

// headers_test.odin — request header parsing and case-insensitive lookup.
// Run with: odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

@(test)
headers_multi :: proc(t: ^testing.T) {
	block := "Host: example.com\r\nContent-Type: application/json\r\nAuthorization: Bearer xyz"
	h, ok := gh.parse_headers(block, context.temp_allocator)
	testing.expect(t, ok, "well-formed header block should parse")

	b := gh.Bifrost {
		req_headers = h,
	}

	ct, ct_ok := gh.header(&b, "content-type")
	testing.expect(t, ct_ok, "Content-Type should be present")
	testing.expect_value(t, ct, "application/json")

	// Lookup is case-insensitive against the stored lower-cased keys.
	host, host_ok := gh.header(&b, "HOST")
	testing.expect(t, host_ok, "Host should be found regardless of case")
	testing.expect_value(t, host, "example.com")

	auth, auth_ok := gh.header(&b, "Authorization")
	testing.expect(t, auth_ok)
	testing.expect_value(t, auth, "Bearer xyz")

	// Missing-header lookup returns ok=false.
	_, miss_ok := gh.header(&b, "Cookie")
	testing.expect(t, !miss_ok, "absent header should report not found")
}

@(test)
headers_malformed :: proc(t: ^testing.T) {
	_, ok := gh.parse_headers("Good: yes\r\nnocolonhere", context.temp_allocator)
	testing.expect(t, !ok, "a line with no colon should be rejected")
}

@(test)
duplicate_content_length_rejected :: proc(t: ^testing.T) {
	// Two Content-Length headers are a request-smuggling desync — reject (400).
	_, ok := gh.parse_headers(
		"Host: x\r\nContent-Length: 5\r\nContent-Length: 6",
		context.temp_allocator,
	)
	testing.expect(t, !ok, "duplicate Content-Length must be rejected")

	// Case-insensitive: the second spelling still collides.
	_, ok2 := gh.parse_headers(
		"content-length: 5\r\nCONTENT-LENGTH: 5",
		context.temp_allocator,
	)
	testing.expect(t, !ok2, "duplicate Content-Length is rejected regardless of case or value")
}

@(test)
duplicate_transfer_encoding_rejected :: proc(t: ^testing.T) {
	_, ok := gh.parse_headers(
		"Host: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: gzip",
		context.temp_allocator,
	)
	testing.expect(t, !ok, "duplicate Transfer-Encoding must be rejected")
}

@(test)
duplicate_non_framing_header_allowed :: proc(t: ^testing.T) {
	// Only the framing headers are strict; other duplicates keep last-wins.
	h, ok := gh.parse_headers("Accept: a\r\nAccept: b", context.temp_allocator)
	testing.expect(t, ok, "a non-framing duplicate should still parse")
	testing.expect_value(t, h["accept"], "b")
}
