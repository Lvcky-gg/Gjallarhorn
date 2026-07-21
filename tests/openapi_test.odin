package tests

// openapi_test.odin — the opt-in OpenAPI docs (openapi.odin): the generated
// spec, the Loom-woven page, and the path helpers. These exercise the pure
// generators directly (no socket), so they assert on the exact output.
// Run with: odin test ./tests

import "core:encoding/json"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

// a couple of stand-in handlers/ward to register routes with.
oa_handler :: proc(b: ^gh.Bifrost) {}
oa_ward :: proc(b: ^gh.Bifrost) -> bool {return true}

// A model to describe routes with — a scalar, a nullable, and a nested slice, so
// the schema/example reflection is exercised end to end.
Oa_Widget :: struct {
	id:    int,
	name:  string,
	price: f64,
	tags:  []string,
	note:  Maybe(string),
}

// oa_app builds an App with a representative route table.
oa_app :: proc() -> gh.App {
	app := gh.new(gh.Config{docs = {enabled = true, title = "Test API", version = "9.9.9"}})
	gh.get(&app, "/things", oa_handler)
	gh.post(&app, "/things", oa_handler)
	gh.get(&app, "/things/:id", oa_handler)
	gh.delete(&app, "/things/:id", oa_handler)
	gh.get(&app, "/account", oa_handler, oa_ward) // guarded
	gh.describe(&app, .Post, "/things", {summary = "Make a widget", request = Oa_Widget, response = Oa_Widget})
	return app
}

@(test)
openapi_spec_is_valid_json :: proc(t: ^testing.T) {
	app := oa_app()
	spec := gh.openapi_spec(&app, context.temp_allocator)

	// It parses — proof the hand-built JSON is well formed.
	val, err := json.parse(transmute([]u8)spec, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "spec is valid JSON")

	root := val.(json.Object)
	testing.expect_value(t, root["openapi"].(json.String), "3.0.3")
	info := root["info"].(json.Object)
	testing.expect_value(t, info["title"].(json.String), "Test API")
	testing.expect_value(t, info["version"].(json.String), "9.9.9")

	paths := root["paths"].(json.Object)
	// ":id" became "{id}" and the two verbs on it are grouped under one path.
	item, ok := paths["/things/{id}"]
	testing.expect(t, ok, "path templated with {id}")
	ops := item.(json.Object)
	_, has_get := ops["get"]
	_, has_del := ops["delete"]
	testing.expect(t, has_get && has_del, "both methods grouped under the path")

	// The templated path carries an {id} path parameter.
	getop := ops["get"].(json.Object)
	params := getop["parameters"].(json.Array)
	testing.expect_value(t, len(params), 1)
	p0 := params[0].(json.Object)
	testing.expect_value(t, p0["name"].(json.String), "id")
	testing.expect_value(t, p0["in"].(json.String), "path")
}

@(test)
openapi_guarded_route_gets_401 :: proc(t: ^testing.T) {
	app := oa_app()
	spec := gh.openapi_spec(&app, context.temp_allocator)
	val, _ := json.parse(transmute([]u8)spec, allocator = context.temp_allocator)
	paths := val.(json.Object)["paths"].(json.Object)
	responses := paths["/account"].(json.Object)["get"].(json.Object)["responses"].(json.Object)
	_, has401 := responses["401"]
	testing.expect(t, has401, "a warded route advertises 401")

	// An open route has no 401.
	open := paths["/things"].(json.Object)["get"].(json.Object)["responses"].(json.Object)
	_, open401 := open["401"]
	testing.expect(t, !open401, "an open route has no 401")
}

@(test)
openapi_page_renders_endpoints :: proc(t: ^testing.T) {
	app := oa_app()
	page := gh.docs_html(&app, context.temp_allocator)

	// It's the Loom-woven HTML, carrying the title, the spec link, and each route.
	testing.expect(t, strings.contains(page, "<!doctype html>"), "an HTML document")
	testing.expect(t, strings.contains(page, "Test API"), "the title")
	testing.expect(t, strings.contains(page, "/api-docs/openapi.json"), "links the spec")
	testing.expect(t, strings.contains(page, ">GET<"), "a GET badge")
	testing.expect(t, strings.contains(page, "/things/:id"), "shows a route path")
	testing.expect(t, strings.contains(page, "guarded"), "flags the warded route")
	// Loom autoescaped the class/method text; no unrendered tags leak through.
	testing.expect(t, !strings.contains(page, "{{"), "no unrendered Loom tags")
}

@(test)
openapi_described_route_has_schema :: proc(t: ^testing.T) {
	app := oa_app()
	spec := gh.openapi_spec(&app, context.temp_allocator)
	val, err := json.parse(transmute([]u8)spec, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "spec is valid JSON")

	post := val.(json.Object)["paths"].(json.Object)["/things"].(json.Object)["post"].(json.Object)
	testing.expect_value(t, post["summary"].(json.String), "Make a widget")

	// requestBody carries the Oa_Widget schema, reflected from the struct.
	schema := post["requestBody"].(json.Object)["content"].(json.Object)["application/json"].(json.Object)["schema"].(json.Object)
	testing.expect_value(t, schema["type"].(json.String), "object")
	props := schema["properties"].(json.Object)
	testing.expect_value(t, props["id"].(json.Object)["type"].(json.String), "integer")
	testing.expect_value(t, props["price"].(json.Object)["type"].(json.String), "number")
	testing.expect_value(t, props["tags"].(json.Object)["type"].(json.String), "array")
	testing.expect_value(t, props["tags"].(json.Object)["items"].(json.Object)["type"].(json.String), "string")
	// Maybe(string) -> a nullable string.
	note := props["note"].(json.Object)
	testing.expect_value(t, note["type"].(json.String), "string")
	testing.expect(t, note["nullable"].(json.Boolean), "Maybe(T) is nullable")

	// The 200 response also carries the schema.
	resp200 := post["responses"].(json.Object)["200"].(json.Object)
	_, has_content := resp200["content"]
	testing.expect(t, has_content, "described response has a schema")
}

@(test)
openapi_example_reflects_struct :: proc(t: ^testing.T) {
	ex := gh.example_json(Oa_Widget, context.temp_allocator)
	// It's valid JSON with placeholder values for each field.
	val, err := json.parse(transmute([]u8)ex, allocator = context.temp_allocator)
	testing.expect(t, err == .None, "example is valid JSON")
	obj := val.(json.Object)
	testing.expect_value(t, obj["name"].(json.String), "string")
	testing.expect_value(t, obj["id"].(json.Float), 0)
	_, is_arr := obj["tags"].(json.Array)
	testing.expect(t, is_arr, "slice field examples as an array")
}

@(test)
openapi_page_has_tryit :: proc(t: ^testing.T) {
	app := oa_app()
	page := gh.docs_html(&app, context.temp_allocator)
	// The interactive bits: a per-route data-path, an Execute control, the fetch
	// script, and (for the described POST) an editable request body.
	testing.expect(t, strings.contains(page, `data-path="/things/:id"`), "route carries its path for JS")
	testing.expect(t, strings.contains(page, "data-exec"), "an Execute button")
	testing.expect(t, strings.contains(page, "await fetch(path, opts)"), "the browser calls the backend")
	testing.expect(t, strings.contains(page, "data-body"), "described POST has an editable body")
	testing.expect(t, strings.contains(page, "Make a widget"), "the summary shows")
}

@(test)
openapi_path_and_params :: proc(t: ^testing.T) {
	testing.expect_value(t, gh.openapi_path("/things/:id", context.temp_allocator), "/things/{id}")
	testing.expect_value(t, gh.openapi_path("/a/:x/b/:y", context.temp_allocator), "/a/{x}/b/{y}")
	testing.expect_value(t, gh.openapi_path("/plain", context.temp_allocator), "/plain")

	names := gh.path_param_names("/a/:x/b/:y", context.temp_allocator)
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "x")
	testing.expect_value(t, names[1], "y")
}
