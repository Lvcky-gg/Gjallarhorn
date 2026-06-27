package tests

// loom_inherit_test.odin — template inheritance: {% extends %} / {% block %}
// (GH-040). Bases are read from the same dir passed to weave, so each test lays
// down fixture templates in a temp dir and weaves the child against it. Run with:
//   odin test ./tests

import "core:os"
import "core:path/filepath"
import "core:testing"
import gh "../gjallarhorn"

Fixture :: struct {
	name:    string,
	content: string,
}

// fixture_dir makes a fresh temp dir and writes each template into it, returning
// the dir. The dir is left for the OS to reap (tests are short-lived).
fixture_dir :: proc(t: ^testing.T, files: []Fixture) -> string {
	dir, derr := os.make_directory_temp("", "loom_test_*", context.temp_allocator)
	testing.expect_value(t, derr, os.ERROR_NONE)
	for f in files {
		path, _ := filepath.join({dir, f.name}, context.temp_allocator)
		werr := os.write_entire_file_from_string(path, f.content)
		testing.expect_value(t, werr, os.ERROR_NONE)
	}
	return dir
}

@(test)
loom_extends_override :: proc(t: ^testing.T) {
	dir := fixture_dir(
		t,
		{
			{"base.html", "<h1>{% block title %}base{% endblock %}</h1>"},
			{"child.html", "{% extends \"base.html\" %}{% block title %}child{% endblock %}"},
		},
	)
	src, _ := os.read_entire_file(filepath.join({dir, "child.html"}, context.temp_allocator) or_else "", context.temp_allocator)
	out, err := gh.weave(string(src), gh.warp(allocator = context.temp_allocator), context.temp_allocator, dir = dir)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "<h1>child</h1>")
}

@(test)
loom_extends_default_fallthrough :: proc(t: ^testing.T) {
	// The child overrides `title` but not `body`; `body` should keep the base
	// default while `title` takes the child's value.
	dir := fixture_dir(
		t,
		{
			{"base.html", "<h1>{% block title %}base-title{% endblock %}</h1><p>{% block body %}base-body{% endblock %}</p>"},
			{"child.html", "{% extends \"base.html\" %}{% block title %}new-title{% endblock %}"},
		},
	)
	src, _ := os.read_entire_file(filepath.join({dir, "child.html"}, context.temp_allocator) or_else "", context.temp_allocator)
	out, err := gh.weave(string(src), gh.warp(allocator = context.temp_allocator), context.temp_allocator, dir = dir)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "<h1>new-title</h1><p>base-body</p>")
}

@(test)
loom_extends_uses_context :: proc(t: ^testing.T) {
	// An overriding block is rendered with the same context the page was given.
	dir := fixture_dir(
		t,
		{
			{"base.html", "{% block greet %}hi{% endblock %}"},
			{"child.html", "{% extends \"base.html\" %}{% block greet %}Hail {{ name }}{% endblock %}"},
		},
	)
	src, _ := os.read_entire_file(filepath.join({dir, "child.html"}, context.temp_allocator) or_else "", context.temp_allocator)
	ctx := gh.warp({"name", "Freyja"}, allocator = context.temp_allocator)
	out, err := gh.weave(string(src), ctx, context.temp_allocator, dir = dir)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "Hail Freyja")
}

@(test)
loom_extends_chain :: proc(t: ^testing.T) {
	// grandchild -> child -> base. The most-derived override of a block wins;
	// blocks left alone fall through to the nearest ancestor that defines them.
	dir := fixture_dir(
		t,
		{
			{"base.html", "[{% block a %}base-a{% endblock %}|{% block b %}base-b{% endblock %}]"},
			{"mid.html", "{% extends \"base.html\" %}{% block a %}mid-a{% endblock %}"},
			{"leaf.html", "{% extends \"mid.html\" %}{% block b %}leaf-b{% endblock %}"},
		},
	)
	src, _ := os.read_entire_file(filepath.join({dir, "leaf.html"}, context.temp_allocator) or_else "", context.temp_allocator)
	out, err := gh.weave(string(src), gh.warp(allocator = context.temp_allocator), context.temp_allocator, dir = dir)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "[mid-a|leaf-b]")
}

@(test)
loom_extends_missing_base :: proc(t: ^testing.T) {
	dir := fixture_dir(
		t,
		{{"child.html", "{% extends \"nope.html\" %}{% block x %}y{% endblock %}"}},
	)
	src, _ := os.read_entire_file(filepath.join({dir, "child.html"}, context.temp_allocator) or_else "", context.temp_allocator)
	_, err := gh.weave(string(src), gh.warp(allocator = context.temp_allocator), context.temp_allocator, dir = dir)
	testing.expect_value(t, err, gh.Loom_Error.Missing_Template)
}

@(test)
loom_block_without_inheritance :: proc(t: ^testing.T) {
	// A standalone template with a block just renders the block's default body.
	out, err := gh.weave(
		"<h1>{% block t %}plain{% endblock %}</h1>",
		gh.warp(allocator = context.temp_allocator),
		context.temp_allocator,
	)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "<h1>plain</h1>")
}
