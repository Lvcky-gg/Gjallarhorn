package tests

// router_test.odin — path matching and percent-decoding (GH-005).
// Run with: odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

@(test)
match_path_decodes_param :: proc(t: ^testing.T) {
	// %20 -> space, %C3%A6 -> 'æ' in the captured :name segment.
	params, ok := gh.match_path("/sample/:name", "/sample/hild%C3%A6r%20the%20bold")
	testing.expect(t, ok, "single segment should match")
	testing.expect_value(t, params["name"], "hildær the bold")
}

@(test)
match_path_literal_segments_raw :: proc(t: ^testing.T) {
	// Literal pattern segments are compared raw; an encoded slash stays inside
	// one segment rather than splitting into two.
	params, ok := gh.match_path("/sample/:id", "/sample/a%2Fb")
	testing.expect(t, ok, "encoded slash must not create a new segment")
	testing.expect_value(t, params["id"], "a/b")
}

@(test)
percent_decode_leaves_plus :: proc(t: ^testing.T) {
	// Unlike form decoding, '+' is literal in a path.
	testing.expect_value(t, gh.percent_decode("a+b%2Bc", context.temp_allocator), "a+b+c")
}
