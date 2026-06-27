package tests

// loom_test.odin — exercises the Loom templating engine end to end. Run with:
//   odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

@(test)
loom_variable :: proc(t: ^testing.T) {
	out, err := gh.weave("Hail {{ name }}!", gh.warp({"name", "Sif"}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "Hail Sif!")
}

@(test)
loom_autoescape :: proc(t: ^testing.T) {
	out, _ := gh.weave("{{ x }}", gh.warp({"x", "<b>&"}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, out, "&lt;b&gt;&amp;")
}

@(test)
loom_safe_filter :: proc(t: ^testing.T) {
	out, _ := gh.weave("{{ x | safe }}", gh.warp({"x", "<b>"}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, out, "<b>")
}

@(test)
loom_dotted_lookup :: proc(t: ^testing.T) {
	ctx := gh.warp({"user", gh.warp({"name", "Heimdallr"}, allocator = context.temp_allocator)}, allocator = context.temp_allocator)
	out, _ := gh.weave("{{ user.name }}", ctx, context.temp_allocator)
	testing.expect_value(t, out, "Heimdallr")
}

@(test)
loom_if_elif_else :: proc(t: ^testing.T) {
	tmpl := "{% if n > 10 %}big{% elif n > 0 %}small{% else %}none{% endif %}"
	a, _ := gh.weave(tmpl, gh.warp({"n", 50}, allocator = context.temp_allocator), context.temp_allocator)
	b, _ := gh.weave(tmpl, gh.warp({"n", 3}, allocator = context.temp_allocator), context.temp_allocator)
	c, _ := gh.weave(tmpl, gh.warp({"n", -1}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, a, "big")
	testing.expect_value(t, b, "small")
	testing.expect_value(t, c, "none")
}

@(test)
loom_for_with_loop :: proc(t: ^testing.T) {
	ctx := gh.warp({"xs", []gh.Value{"a", "b", "c"}}, allocator = context.temp_allocator)
	out, _ := gh.weave("{% for x in xs %}{{ loop.index }}:{{ x }} {% endfor %}", ctx, context.temp_allocator)
	testing.expect_value(t, out, "1:a 2:b 3:c ")
}

@(test)
loom_for_empty_else :: proc(t: ^testing.T) {
	ctx := gh.warp({"xs", []gh.Value{}}, allocator = context.temp_allocator)
	out, _ := gh.weave("{% for x in xs %}{{ x }}{% else %}empty{% endfor %}", ctx, context.temp_allocator)
	testing.expect_value(t, out, "empty")
}

@(test)
loom_filter_pipeline :: proc(t: ^testing.T) {
	ctx := gh.warp({"name", "loki"}, allocator = context.temp_allocator)
	out, _ := gh.weave("{{ name | upper }} / {{ missing | default('n/a') }}", ctx, context.temp_allocator)
	testing.expect_value(t, out, "LOKI / n/a")
}

@(test)
loom_comment_dropped :: proc(t: ^testing.T) {
	out, _ := gh.weave("a{# hidden #}b", gh.warp(allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, out, "ab")
}

@(test)
loom_unclosed_block_errors :: proc(t: ^testing.T) {
	_, err := gh.weave("{% if x %}oops", gh.warp({"x", true}, allocator = context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, err, gh.Loom_Error.Unexpected_End)
}
