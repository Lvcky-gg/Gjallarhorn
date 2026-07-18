package tests

// loom_cache_uaf_test.odin — regression for the heap-use-after-free where a
// cached template's {% include %}/{% extends %} name pointed into the temp arena
// of the request that parsed it. load_template caches the node tree on the heap,
// but string_literal used to return lex_expr's temp-allocated literal, so the
// cached node's `text` dangled once the parsing worker's temp arena was freed —
// the next render (a cache hit, possibly on another thread) read freed memory.
//
// This exercises the real cached path (gh.weave_file), then resets + clobbers the
// temp arena between renders so a dangling pointer reads garbage deterministically
// (AddressSanitizer flags it directly; without ASan the include mis-resolves).
// Run with: odin test ./tests

import "core:path/filepath"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

@(test)
cached_include_name_survives_temp_reset :: proc(t: ^testing.T) {
	dir := fixture_dir(
		t,
		{
			{"foot.html", "<footer>end</footer>"},
			{"pg.html", "<main>{% include \"foot.html\" %}</main>"},
		},
	)
	// dir is temp-allocated; keep the page path alive across the reset below.
	pg, _ := filepath.join({dir, "pg.html"}, context.temp_allocator)
	page := strings.clone(pg, context.allocator)
	defer delete(page, context.allocator)

	// First render: cache miss → parses and caches the tree.
	out1, err1 := gh.weave_file(page, gh.warp(allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, err1, gh.Loom_Error.None)
	testing.expect_value(t, out1, "<main><footer>end</footer></main>")

	// Simulate the parsing request's teardown: reset the temp arena and scribble
	// over it, so a dangling include-name pointer reads clobbered bytes rather
	// than the (possibly still-intact) originals.
	free_all(context.temp_allocator)
	clobber := make([]u8, 256 * 1024, context.temp_allocator)
	for i in 0 ..< len(clobber) {
		clobber[i] = 0x5A
	}

	// Second render: cache hit → reads the cached include name. Post-fix it lives
	// on the cache heap and resolves; pre-fix it read the clobbered arena.
	out2, err2 := gh.weave_file(page, gh.warp(allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, err2, gh.Loom_Error.None)
	testing.expect_value(t, out2, "<main><footer>end</footer></main>")
}

@(test)
cached_extends_name_survives_temp_reset :: proc(t: ^testing.T) {
	// Same defect via {% extends %}: the base-template name is also a string
	// literal retained in the cached child node.
	dir := fixture_dir(
		t,
		{
			{"base.html", "<h1>{% block t %}base{% endblock %}</h1>"},
			{"child.html", "{% extends \"base.html\" %}{% block t %}child{% endblock %}"},
		},
	)
	ch, _ := filepath.join({dir, "child.html"}, context.temp_allocator)
	page := strings.clone(ch, context.allocator)
	defer delete(page, context.allocator)

	out1, err1 := gh.weave_file(page, gh.warp(allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, err1, gh.Loom_Error.None)
	testing.expect_value(t, out1, "<h1>child</h1>")

	free_all(context.temp_allocator)
	clobber := make([]u8, 256 * 1024, context.temp_allocator)
	for i in 0 ..< len(clobber) {
		clobber[i] = 0x5A
	}

	out2, err2 := gh.weave_file(page, gh.warp(allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, err2, gh.Loom_Error.None)
	testing.expect_value(t, out2, "<h1>child</h1>")
}
