package tests

// static_cache_test.odin — static-file caching (ETag / Last-Modified / 304) and
// precompressed gzip_static. Pure helpers plus socket-level serve_static calls
// (reusing open_pair + fixture_dir). Run with: odin test ./tests

import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import gh "../gjallarhorn"

// serve1 runs serve_static for one request against a fresh socket pair and
// returns the raw HTTP response the server wrote.
serve1 :: proc(
	t: ^testing.T,
	dir, path: string,
	req_headers: map[string]string,
) -> (
	resp: string,
	ok: bool,
) {
	server, client, paired := open_pair(t)
	if !paired {
		return "", false
	}
	defer net.close(server)
	defer net.close(client)

	b := gh.Bifrost {
		method      = .Get,
		path        = path,
		client      = server,
		req_headers = req_headers,
	}
	gh.serve_static(&b, gh.Static_Mount{url_prefix = "/s", dir = dir})

	buf: [8192]u8
	n, _ := net.recv_tcp(client, buf[:])
	return strings.clone(string(buf[:n]), context.temp_allocator), true
}

header_value :: proc(resp, name: string) -> (string, bool) {
	for line in strings.split(resp, "\r\n", context.temp_allocator) {
		if strings.has_prefix(strings.to_lower(line, context.temp_allocator), strings.to_lower(strings.concatenate({name, ":"}, context.temp_allocator), context.temp_allocator)) {
			_, _, rest := strings.partition(line, ":")
			return strings.trim_space(rest), true
		}
	}
	return "", false
}

body_of :: proc(resp: string) -> string {
	if i := strings.index(resp, "\r\n\r\n"); i >= 0 {
		return resp[i + 4:]
	}
	return ""
}

@(test)
static_serves_with_validators :: proc(t: ^testing.T) {
	dir := fixture_dir(t, {{"style.css", "body{color:red}"}})
	resp, ok := serve1(t, dir, "/s/style.css", nil)
	if !ok {return}

	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200"), "200 for a present file")
	testing.expect(t, strings.contains(resp, "Content-Type: text/css"), "css content type")
	testing.expect_value(t, body_of(resp), "body{color:red}")

	_, has_etag := header_value(resp, "ETag")
	_, has_lm := header_value(resp, "Last-Modified")
	cc, has_cc := header_value(resp, "Cache-Control")
	testing.expect(t, has_etag, "ETag present")
	testing.expect(t, has_lm, "Last-Modified present")
	testing.expect(t, has_cc && strings.contains(cc, "max-age"), "Cache-Control present")
}

@(test)
static_conditional_304 :: proc(t: ^testing.T) {
	dir := fixture_dir(t, {{"a.txt", "hello"}})

	first, ok := serve1(t, dir, "/s/a.txt", nil)
	if !ok {return}
	etag, _ := header_value(first, "ETag")
	last_mod, _ := header_value(first, "Last-Modified")

	// If-None-Match with the ETag -> 304, no body.
	h1 := make(map[string]string, context.temp_allocator)
	h1["if-none-match"] = etag
	resp, _ := serve1(t, dir, "/s/a.txt", h1)
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 304"), "matching ETag -> 304")
	testing.expect_value(t, body_of(resp), "")

	// A stale ETag still transfers the body.
	h2 := make(map[string]string, context.temp_allocator)
	h2["if-none-match"] = "\"nope\""
	resp2, _ := serve1(t, dir, "/s/a.txt", h2)
	testing.expect(t, strings.has_prefix(resp2, "HTTP/1.1 200"), "stale ETag -> 200")
	testing.expect_value(t, body_of(resp2), "hello")

	// If-Modified-Since equal to Last-Modified -> 304.
	h3 := make(map[string]string, context.temp_allocator)
	h3["if-modified-since"] = last_mod
	resp3, _ := serve1(t, dir, "/s/a.txt", h3)
	testing.expect(t, strings.has_prefix(resp3, "HTTP/1.1 304"), "unchanged since -> 304")
}

@(test)
static_gzip_precompressed :: proc(t: ^testing.T) {
	// The .gz holds arbitrary bytes: the framework serves it verbatim with
	// Content-Encoding: gzip; it never compresses or decompresses.
	dir := fixture_dir(
		t,
		{{"app.js", "console.log(1)"}, {"app.js.gz", "GZIPPED-BYTES"}},
	)

	// Client accepts gzip -> the .gz is served, but typed as the original JS.
	hg := make(map[string]string, context.temp_allocator)
	hg["accept-encoding"] = "gzip, deflate, br"
	resp, ok := serve1(t, dir, "/s/app.js", hg)
	if !ok {return}
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200"), "200")
	testing.expect_value(t, body_of(resp), "GZIPPED-BYTES")
	ce, _ := header_value(resp, "Content-Encoding")
	testing.expect_value(t, ce, "gzip")
	vary, _ := header_value(resp, "Vary")
	testing.expect_value(t, vary, "Accept-Encoding")
	testing.expect(t, strings.contains(resp, "Content-Type: text/javascript"), "typed as JS")

	// Same resource, client does NOT accept gzip -> identity bytes, no
	// Content-Encoding, but Vary still set so caches don't cross the streams.
	resp2, _ := serve1(t, dir, "/s/app.js", nil)
	testing.expect_value(t, body_of(resp2), "console.log(1)")
	_, has_ce := header_value(resp2, "Content-Encoding")
	testing.expect(t, !has_ce, "no Content-Encoding when gzip not accepted")
	vary2, _ := header_value(resp2, "Vary")
	testing.expect_value(t, vary2, "Accept-Encoding")
}

@(test)
http_date_matches_rfc_example :: proc(t: ^testing.T) {
	// RFC 7231's own IMF-fixdate example — checks weekday, month, and padding.
	when_, _ := time.components_to_time(1994, 11, 6, 8, 49, 37)
	testing.expect_value(t, gh.http_date(when_), "Sun, 06 Nov 1994 08:49:37 GMT")
}

@(test)
static_not_modified_rules :: proc(t: ^testing.T) {
	etag := "\"abc-123\""
	lm := "Sun, 06 Nov 1994 08:49:37 GMT"

	mk :: proc(k, v: string) -> ^gh.Bifrost {
		b := new(gh.Bifrost, context.temp_allocator)
		b.req_headers = make(map[string]string, context.temp_allocator)
		if k != "" {b.req_headers[k] = v}
		return b
	}
	testing.expect(t, gh.static_not_modified(mk("if-none-match", etag), etag, lm))
	testing.expect(t, gh.static_not_modified(mk("if-none-match", "*"), etag, lm))
	testing.expect(t, !gh.static_not_modified(mk("if-none-match", "\"other\""), etag, lm))
	testing.expect(t, gh.static_not_modified(mk("if-modified-since", lm), etag, lm))
	testing.expect(t, !gh.static_not_modified(mk("", ""), etag, lm))
}
