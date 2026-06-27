package tests

// loom_warp_of_test.odin — reflecting typed structs straight into a Warp so an
// ORM row renders without hand-built maps (GH-043). Run with: odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

Profile :: struct {
	city: string,
	zip:  int,
}

Account :: struct {
	name:    string,
	age:     int,
	admin:   bool,
	balance: f64,
	profile: Profile,
	tags:    []string,
	secret:  string `loom:"-"`,
	display: string `loom:"shown"`,
}

@(test)
loom_warp_of_scalars :: proc(t: ^testing.T) {
	a := Account{name = "Sif", age = 30, admin = true, balance = 12.5}
	ctx := gh.warp_of(a, context.temp_allocator)
	out, err := gh.weave(
		"{{ name }} {{ age }} {{ balance }} {% if admin %}yes{% else %}no{% endif %}",
		ctx,
		context.temp_allocator,
	)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "Sif 30 12.5 yes")
}

@(test)
loom_warp_of_nested_struct :: proc(t: ^testing.T) {
	a := Account{name = "Bragi", profile = Profile{city = "Asgard", zip = 1}}
	ctx := gh.warp_of(a, context.temp_allocator)
	out, _ := gh.weave("{{ profile.city }}/{{ profile.zip }}", ctx, context.temp_allocator)
	testing.expect_value(t, out, "Asgard/1")
}

@(test)
loom_warp_of_slice_field :: proc(t: ^testing.T) {
	a := Account{tags = []string{"a", "b", "c"}}
	ctx := gh.warp_of(a, context.temp_allocator)
	out, _ := gh.weave("{% for x in tags %}{{ x }}{% endfor %}", ctx, context.temp_allocator)
	testing.expect_value(t, out, "abc")
}

@(test)
loom_warp_of_tag_rename_and_skip :: proc(t: ^testing.T) {
	a := Account{secret = "hunter2", display = "Hi"}
	ctx := gh.warp_of(a, context.temp_allocator)

	// `loom:"-"` drops the field — `secret` resolves to nothing.
	out, _ := gh.weave("[{{ secret }}]", ctx, context.temp_allocator)
	testing.expect_value(t, out, "[]")

	// `loom:"shown"` renames the key.
	out2, _ := gh.weave("{{ shown }}", ctx, context.temp_allocator)
	testing.expect_value(t, out2, "Hi")
}

@(test)
loom_warp_of_pointer :: proc(t: ^testing.T) {
	a := Account{name = "Freya", age = 7}
	ctx := gh.warp_of(&a, context.temp_allocator) // pointer is followed
	out, _ := gh.weave("{{ name }}:{{ age }}", ctx, context.temp_allocator)
	testing.expect_value(t, out, "Freya:7")
}

@(test)
loom_warp_of_rows_list :: proc(t: ^testing.T) {
	// A slice of scanned rows -> []Value of nested Warps, ready to loop over.
	rows := []Account{{name = "Odin", age = 1}, {name = "Thor", age = 2}}
	ctx := gh.warp({"users", gh.value_of(rows, context.temp_allocator)}, allocator = context.temp_allocator)
	out, err := gh.weave(
		"{% for u in users %}{{ u.name }}={{ u.age }};{% endfor %}",
		ctx,
		context.temp_allocator,
	)
	testing.expect_value(t, err, gh.Loom_Error.None)
	testing.expect_value(t, out, "Odin=1;Thor=2;")
}
