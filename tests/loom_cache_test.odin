package tests

// loom_cache_test.odin — the compiled-node cache (GH-042). A template read from
// disk is lexed/parsed once and reused until its mtime changes. Shares
// fixture_dir with loom_inherit_test.odin. Run with: odin test ./tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import gh "../gjallarhorn"

@(test)
loom_cache_reuses_parse :: proc(t: ^testing.T) {
	dir := fixture_dir(t, {{"page.html", "<h1>{{ name }}</h1>"}})
	path, _ := filepath.join({dir, "page.html"}, context.temp_allocator)

	for _ in 0 ..< 5 {
		out, err := gh.weave_file(path, gh.warp({"name", "Thor"}, allocator = context.temp_allocator), context.temp_allocator)
		testing.expect_value(t, err, gh.Loom_Error.None)
		testing.expect_value(t, out, "<h1>Thor</h1>")
	}
	// Five renders of one unchanged file -> exactly one parse.
	testing.expect_value(t, gh.loaded_parse_count(path), 1)
}

@(test)
loom_cache_invalidates_on_change :: proc(t: ^testing.T) {
	dir := fixture_dir(t, {{"page.html", "old {{ x }}"}})
	path, _ := filepath.join({dir, "page.html"}, context.temp_allocator)

	a, _ := gh.weave_file(path, gh.warp({"x", "v"}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, a, "old v")
	testing.expect_value(t, gh.loaded_parse_count(path), 1)

	// Rewrite with new content. Sleep first so the mtime is guaranteed to advance
	// past the filesystem's timestamp resolution.
	time.sleep(20 * time.Millisecond)
	werr := os.write_entire_file_from_string(path, "new {{ x }}")
	testing.expect_value(t, werr, os.ERROR_NONE)

	b, _ := gh.weave_file(path, gh.warp({"x", "v"}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, b, "new v") // cache saw the change
	// The change forced a second parse of this path.
	testing.expect_value(t, gh.loaded_parse_count(path), 2)
}

@(test)
loom_cache_benchmark :: proc(t: ^testing.T) {
	// A tag-dense template so parsing is a real share of the work, then compare
	// re-parsing every render (weave) against the cached path (weave_file).
	// tmpl and path live on the heap so the per-iteration free_all(temp) below
	// can't reclaim them mid-loop.
	sb := strings.builder_make(context.allocator)
	for _ in 0 ..< 40 {
		strings.write_string(
			&sb,
			"<li>{% if on %}{{ name | upper }}{% else %}{{ name | lower }}{% endif %} #{{ n }}</li>\n",
		)
	}
	tmpl := strings.to_string(sb)
	defer delete(tmpl)

	dir := fixture_dir(t, {{"bench.html", tmpl}})
	path, _ := filepath.join({dir, "bench.html"}, context.allocator)
	defer delete(path)
	// Context on the heap so the per-iteration temp free_all doesn't reclaim it.
	ctx := gh.warp({"name", "Freyr"}, {"on", true}, {"n", 7}, allocator = context.allocator)
	defer delete(ctx)

	N :: 4000

	gh.weave_file(path, ctx, context.temp_allocator) // warm the cache

	t0 := time.now()
	for _ in 0 ..< N {
		gh.weave_file(path, ctx, context.temp_allocator)
		free_all(context.temp_allocator)
	}
	cached := time.since(t0)

	t1 := time.now()
	for _ in 0 ..< N {
		gh.weave(tmpl, ctx, context.temp_allocator)
		free_all(context.temp_allocator)
	}
	uncached := time.since(t1)

	fmt.printfln(
		"loom cache over %d renders: cached %v vs re-parse %v (%.1fx)",
		N,
		cached,
		uncached,
		f64(uncached) / f64(cached),
	)
	testing.expect(t, cached < uncached, "cached weave_file should beat re-parsing every render")
}
