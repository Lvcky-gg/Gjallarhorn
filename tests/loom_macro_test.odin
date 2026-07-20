package tests

// loom_macro_test.odin — {% macro %} / {% endmacro %} definitions, {{ name(args) }}
// calls, and {% import %} to reuse macros across files. Uses the fixture_dir +
// weave_file helpers from the sibling loom tests. Run with: odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

@(test)
loom_macro_basic :: proc(t: ^testing.T) {
	dir := fixture_dir(
		t,
		{
			{
				"page.html",
				"{% macro greet(who) %}Hail, {{ who }}!{% endmacro %}[{{ greet(\"Heimdallr\") }}]",
			},
		},
	)
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "[Hail, Heimdallr!]")
}

@(test)
loom_macro_multiple_params :: proc(t: ^testing.T) {
	dir := fixture_dir(
		t,
		{
			{
				"page.html",
				"{% macro field(name, label) %}<label>{{ label }}<input name=\"{{ name }}\"></label>{% endmacro %}" +
				"{{ field(\"email\", \"Email\") }}",
			},
		},
	)
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "<label>Email<input name=\"email\"></label>")
}

@(test)
loom_macro_call_before_definition :: proc(t: ^testing.T) {
	// Macros are hoisted, so a call may appear before its {% macro %}.
	dir := fixture_dir(
		t,
		{{"page.html", "{{ shout(\"go\") }}{% macro shout(s) %}{{ s }}!{% endmacro %}"}},
	)
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "go!")
}

@(test)
loom_macro_escaping :: proc(t: ^testing.T) {
	// The macro's own markup is emitted verbatim (it's the author's HTML), but a
	// value interpolated through {{ param }} is still escaped — no double-escape,
	// no XSS hole.
	dir := fixture_dir(
		t,
		{{"page.html", "{% macro em(x) %}<em>{{ x }}</em>{% endmacro %}{{ em(\"<b>hi</b>\") }}"}},
	)
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "<em>&lt;b&gt;hi&lt;/b&gt;</em>")
}

@(test)
loom_macro_body_uses_logic :: proc(t: ^testing.T) {
	// A macro body is a normal template fragment: it can branch and loop.
	dir := fixture_dir(
		t,
		{
			{
				"page.html",
				"{% macro badge(n) %}{% if n %}({{ n }}){% else %}-{% endif %}{% endmacro %}" +
				"{{ badge(\"admin\") }}{{ badge(\"\") }}",
			},
		},
	)
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "(admin)-")
}

@(test)
loom_macro_missing_arg_is_empty :: proc(t: ^testing.T) {
	// Fewer args than params: the unfilled parameter is nil, renders empty —
	// consistent with how an unknown variable evaluates.
	dir := fixture_dir(
		t,
		{{"page.html", "{% macro pair(a, b) %}{{ a }}/{{ b }}{% endmacro %}{{ pair(\"x\") }}"}},
	)
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "x/")
}

@(test)
loom_macro_unknown_call_is_empty :: proc(t: ^testing.T) {
	// Calling a macro that doesn't exist renders nothing, like a missing var —
	// never a crash.
	dir := fixture_dir(t, {{"page.html", "a{{ nope(\"x\") }}b"}})
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "ab")
}

@(test)
loom_macro_import :: proc(t: ^testing.T) {
	// Reuse macros defined in another file via {% import %}.
	dir := fixture_dir(
		t,
		{
			{"forms.html", "{% macro field(n) %}<input name=\"{{ n }}\">{% endmacro %}"},
			{"page.html", "{% import \"forms.html\" %}<form>{{ field(\"q\") }}</form>"},
		},
	)
	out, err := weave_file(dir, "page.html", gh.warp(allocator = context.temp_allocator))
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "<form><input name=\"q\"></form>")
}
