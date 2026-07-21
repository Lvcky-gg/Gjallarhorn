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

// oa_app builds an App with a representative route table.
oa_app :: proc() -> gh.App {
	app := gh.new(gh.Config{docs = {enabled = true, title = "Test API", version = "9.9.9"}})
	gh.get(&app, "/things", oa_handler)
	gh.post(&app, "/things", oa_handler)
	gh.get(&app, "/things/:id", oa_handler)
	gh.delete(&app, "/things/:id", oa_handler)
	gh.get(&app, "/account", oa_handler, oa_ward) // guarded
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
openapi_path_and_params :: proc(t: ^testing.T) {
	testing.expect_value(t, gh.openapi_path("/things/:id", context.temp_allocator), "/things/{id}")
	testing.expect_value(t, gh.openapi_path("/a/:x/b/:y", context.temp_allocator), "/a/{x}/b/{y}")
	testing.expect_value(t, gh.openapi_path("/plain", context.temp_allocator), "/plain")

	names := gh.path_param_names("/a/:x/b/:y", context.temp_allocator)
	testing.expect_value(t, len(names), 2)
	testing.expect_value(t, names[0], "x")
	testing.expect_value(t, names[1], "y")
}
