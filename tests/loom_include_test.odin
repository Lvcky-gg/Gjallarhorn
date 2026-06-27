package tests

// loom_include_test.odin — {% include "partial.html" %} (GH-041). Partials are
// read from the dir passed to weave and rendered against the current context;
// the path is traversal-clamped like the static mounts. Shares fixture_dir with
// loom_inherit_test.odin. Run with: odin test ./tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import gh "../gjallarhorn"

// weave_file reads `name` from `dir` and weaves it with `dir` as the resolution
// root — the shape the HTTP glue uses for a mounted page.
weave_file :: proc(dir, name: string, ctx: gh.Warp) -> (string, gh.Loom_Error) {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	src, _ := os.read_entire_file(path, context.temp_allocator)
	return gh.weave(string(src), ctx, context.temp_allocator, dir = dir)
}

@(test)
loom_include_basic :: proc(t: ^testing.T) {
	dir := fixture_dir(
		t,
		{
			{"nav.html", "<nav>menu</nav>"},
			{"page.html", "<body>{% include \"nav.html\" %}<main>hi</main></body>"},
		},
	)
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "<body><nav>menu</nav><main>hi</main></body>")
}

@(test)
loom_include_shares_context :: proc(t: ^testing.T) {
	// The partial sees the same context the including page was given.
	dir := fixture_dir(
		t,
		{
			{"hello.html", "Hail {{ name }}"},
			{"page.html", "[{% include \"hello.html\" %}]"},
		},
	)
	ctx := gh.warp({"name", "Odin"}, allocator = context.temp_allocator)
	out, err := weave_file(dir, "page.html", ctx)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "[Hail Odin]")
}

@(test)
loom_include_in_loop :: proc(t: ^testing.T) {
	// Included inside a for-loop, the partial sees each iteration's bindings.
	dir := fixture_dir(
		t,
		{
			{"row.html", "<li>{{ loop.index }}:{{ x }}</li>"},
			{"page.html", "<ul>{% for x in xs %}{% include \"row.html\" %}{% endfor %}</ul>"},
		},
	)
	ctx := gh.warp({"xs", []gh.Value{"a", "b"}}, allocator = context.temp_allocator)
	out, err := weave_file(dir, "page.html", ctx)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "<ul><li>1:a</li><li>2:b</li></ul>")
}

@(test)
loom_include_partial_can_extend :: proc(t: ^testing.T) {
	// A partial resolves its own inheritance: the included template extends a base.
	dir := fixture_dir(
		t,
		{
			{"card_base.html", "<div>{% block c %}base{% endblock %}</div>"},
			{"card.html", "{% extends \"card_base.html\" %}{% block c %}filled{% endblock %}"},
			{"page.html", "({% include \"card.html\" %})"},
		},
	)
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "(<div>filled</div>)")
}

@(test)
loom_include_traversal_clamped :: proc(t: ^testing.T) {
	// A partial name that climbs out of the mount dir is refused, like the mounts.
	dir := fixture_dir(
		t,
		{{"page.html", "{% include \"../escape.html\" %}"}},
	)
	_, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.Forbidden_Path)
}

@(test)
loom_include_missing :: proc(t: ^testing.T) {
	dir := fixture_dir(
		t,
		{{"page.html", "{% include \"gone.html\" %}"}},
	)
	_, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.Missing_Template)
}

@(test)
loom_include_cycle_guarded :: proc(t: ^testing.T) {
	// Two partials that include each other hit the depth guard instead of
	// recursing until the stack dies.
	dir := fixture_dir(
		t,
		{
			{"a.html", "{% include \"b.html\" %}"},
			{"b.html", "{% include \"a.html\" %}"},
		},
	)
	_, err := weave_file(dir, "a.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.Include_Too_Deep)
}
