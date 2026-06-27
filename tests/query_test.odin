package tests

// query_test.odin — query-string parsing and lookup (GH-004).
// Run with: odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

@(test)
query_parses_and_decodes :: proc(t: ^testing.T) {
	// '+' -> space and %2C -> ',' should be decoded.
	q := gh.parse_query("q=hail+all&tags=a%2Cb&blank=", context.temp_allocator)
	b := gh.Bifrost {
		query = q,
	}

	v, ok := gh.query(&b, "q")
	testing.expect(t, ok, "q should be present")
	testing.expect_value(t, v, "hail all")

	tags, _ := gh.query(&b, "tags")
	testing.expect_value(t, tags, "a,b")

	blank, blank_ok := gh.query(&b, "blank")
	testing.expect(t, blank_ok, "empty-valued key is still present")
	testing.expect_value(t, blank, "")

	_, miss := gh.query(&b, "missing")
	testing.expect(t, !miss, "absent key reports not found")
}
