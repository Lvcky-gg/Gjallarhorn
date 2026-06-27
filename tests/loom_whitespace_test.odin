package tests

// loom_whitespace_test.odin — Jinja-style whitespace control: a `-` on either
// delimiter ({%- -%}, {{- -}}, {#- -#}) trims adjacent whitespace (GH-044).
// Run with: odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

@(test)
loom_ws_trim_left :: proc(t: ^testing.T) {
	out, _ := gh.weave("a   {%- if on %}b{% endif %}", gh.warp({"on", true}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, out, "ab")
}

@(test)
loom_ws_trim_right :: proc(t: ^testing.T) {
	// The trailing `-` swallows the whitespace that opens the if body.
	out, _ := gh.weave("{% if on -%}   b{% endif %}", gh.warp({"on", true}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, out, "b")
}

@(test)
loom_ws_output_both_sides :: proc(t: ^testing.T) {
	out, _ := gh.weave("a {{- x -}} b", gh.warp({"x", "X"}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, out, "aXb")
}

@(test)
loom_ws_comment :: proc(t: ^testing.T) {
	out, _ := gh.weave("a {#- hidden -#} b", gh.warp(allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, out, "ab")
}

@(test)
loom_ws_no_marker_keeps_whitespace :: proc(t: ^testing.T) {
	// Without a `-`, surrounding whitespace is preserved exactly as before.
	out, _ := gh.weave("a {{ x }} b", gh.warp({"x", "X"}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, out, "a X b")
}

@(test)
loom_ws_trims_newlines :: proc(t: ^testing.T) {
	// `-` trims newlines too, not just spaces.
	out, _ := gh.weave("x\n{%- if on %}y{% endif %}", gh.warp({"on", true}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, out, "xy")
}

@(test)
loom_ws_loop_clean_output :: proc(t: ^testing.T) {
	// The motivating case: `-` on the for/endfor delimiters strips the stray
	// newlines the tags would otherwise leave, so the list renders tidily.
	tmpl := `<ul>
{%- for x in xs %}
  <li>{{ x }}</li>
{%- endfor %}
</ul>`
	want := `<ul>
  <li>a</li>
  <li>b</li>
</ul>`
	ctx := gh.warp({"xs", []gh.Value{"a", "b"}}, allocator = context.temp_allocator)
	out, err := gh.weave(tmpl, ctx, context.temp_allocator)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, want)
}
