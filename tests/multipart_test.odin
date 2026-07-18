package tests

// multipart_test.odin — multipart/form-data decoding (file uploads). Verifies
// text fields land in form() (so CSRF/inputs work under multipart too), files
// land in files()/upload(), binary content is preserved byte-for-byte, and a
// non-multipart body still decodes as urlencoded. Run with: odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

// mp_bifrost builds a Bifrost carrying `body` with the given Content-Type, the
// shape the parser sees after read_request.
mp_bifrost :: proc(body: string, content_type: string) -> gh.Bifrost {
	b := gh.Bifrost {
		body      = transmute([]u8)body,
		body_text = body,
	}
	b.req_headers = make(map[string]string, context.temp_allocator)
	b.req_headers["content-type"] = content_type
	return b
}

@(test)
multipart_fields_and_file :: proc(t: ^testing.T) {
	body :: "--BND\r\n" +
		"Content-Disposition: form-data; name=\"title\"\r\n\r\n" +
		"Hello World\r\n" +
		"--BND\r\n" +
		"Content-Disposition: form-data; name=\"avatar\"; filename=\"pic.png\"\r\n" +
		"Content-Type: image/png\r\n\r\n" +
		"\x89PNGdata\r\n" +
		"--BND--\r\n"
	b := mp_bifrost(body, "multipart/form-data; boundary=BND")

	testing.expect_value(t, gh.form(&b)["title"], "Hello World")

	f, ok := gh.upload(&b, "avatar")
	testing.expect(t, ok, "avatar file part should be present")
	testing.expect_value(t, f.filename, "pic.png")
	testing.expect_value(t, f.content_type, "image/png")
	testing.expect_value(t, string(f.data), "\x89PNGdata")

	// A text field is not a file, and vice versa.
	_, is_file := gh.upload(&b, "title")
	testing.expect(t, !is_file, "a text field must not appear as a file")
}

@(test)
multipart_preserves_binary_content :: proc(t: ^testing.T) {
	// File bytes carrying CRLFs and a boundary-looking run (but not the real
	// "\r\n--BND" delimiter) must survive exactly.
	payload :: "a\r\nb--BNDc\x00\xffz"
	body :: "--BND\r\n" +
		"Content-Disposition: form-data; name=\"f\"; filename=\"raw.bin\"\r\n" +
		"Content-Type: application/octet-stream\r\n\r\n" +
		payload +
		"\r\n--BND--\r\n"
	b := mp_bifrost(body, "multipart/form-data; boundary=BND")

	f, ok := gh.upload(&b, "f")
	testing.expect(t, ok, "binary file part present")
	testing.expect_value(t, len(f.data), len(payload))
	testing.expect_value(t, string(f.data), payload)
}

@(test)
multipart_csrf_token_visible_in_form :: proc(t: ^testing.T) {
	// A CSRF token submitted as a multipart field must be reachable through
	// form(), the same path csrf_presented_token uses — so multipart POSTs pass.
	body :: "--B\r\n" +
		"Content-Disposition: form-data; name=\"csrf_token\"\r\n\r\n" +
		"TOK-123\r\n" +
		"--B--\r\n"
	b := mp_bifrost(body, "multipart/form-data; boundary=B")
	testing.expect_value(t, gh.form(&b)["csrf_token"], "TOK-123")
}

@(test)
multipart_quoted_boundary :: proc(t: ^testing.T) {
	body :: "--Z9\r\n" +
		"Content-Disposition: form-data; name=\"k\"\r\n\r\n" +
		"v\r\n" +
		"--Z9--\r\n"
	b := mp_bifrost(body, "multipart/form-data; boundary=\"Z9\"")
	testing.expect_value(t, gh.form(&b)["k"], "v")
}

@(test)
non_multipart_body_is_urlencoded :: proc(t: ^testing.T) {
	// The historic path is unchanged: a urlencoded body still decodes as fields,
	// with no files.
	b := mp_bifrost("a=1&b=hello+world", "application/x-www-form-urlencoded")
	testing.expect_value(t, gh.form(&b)["a"], "1")
	testing.expect_value(t, gh.form(&b)["b"], "hello world")
	testing.expect_value(t, len(gh.files(&b)), 0)
}

@(test)
multipart_boundary_detection :: proc(t: ^testing.T) {
	bnd, ok := gh.multipart_boundary("multipart/form-data; boundary=abc123")
	testing.expect(t, ok, "boundary should be detected")
	testing.expect_value(t, bnd, "abc123")

	_, ok2 := gh.multipart_boundary("text/plain; charset=utf-8")
	testing.expect(t, !ok2, "non-multipart type has no boundary")

	_, ok3 := gh.multipart_boundary("multipart/form-data")
	testing.expect(t, !ok3, "multipart without a boundary is rejected")
}
