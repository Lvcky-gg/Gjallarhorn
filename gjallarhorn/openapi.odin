package gjallarhorn

// openapi.odin — a self-describing docs page, woven by Loom from the routes the
// router already knows. It is opt-in: Config.docs.enabled is false by default, so
// nothing is mounted and nothing costs you until you ask (a public app usually
// wants this off). Flip it on and two GET routes appear:
//
//   {docs.path}                 an HTML page (rendered by Loom) with a live "Try it"
//   {docs.path}/openapi.json    an OpenAPI 3.0 document
//
// Both are generated from app.routes at *request* time, so they always reflect the
// live route table — register a route and it shows up. Give a route request/response
// types with `describe` and its body schema, an example value, and a filled-in
// "Try it" form all follow (Swagger-style), reflected straight from the structs:
//
//   gh.get(&app, "/sample/:id", get_handler)
//   gh.describe(&app, .Get, "/sample/:id", {summary = "Fetch one sample", response = Sample})
//   gh.post(&app, "/sample", create_handler)
//   gh.describe(&app, .Post, "/sample", {request = Sample, response = Sample})
//
// What isn't described is honestly omitted rather than invented, in keeping with
// the rest of the framework.

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"
import "core:time"

// describe attaches an OpenAPI annotation to a route (matched by method+path).
// Optional and additive: routes without one still appear, just without a schema.
describe :: proc(app: ^App, method: Method, path: string, doc: Route_Doc) {
	if app.route_docs == nil {
		app.route_docs = make(map[string]Route_Doc)
	}
	app.route_docs[route_key(method, path, context.allocator)] = doc
}

// route_key is the "METHOD path" key route_docs is stored under.
@(private)
route_key :: proc(m: Method, path: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({method_name(m), " ", path}, allocator)
}

// mount_docs registers the docs routes when enabled. Called from run() after the
// app's own routes are all in, so the generated spec sees the whole table. Fills
// in the defaults here (once, at startup) so the handlers can read them back.
mount_docs :: proc(app: ^App) {
	if !app.docs.enabled {
		return
	}
	if app.docs.path == "" {
		app.docs.path = "/api-docs"
	}
	if app.docs.title == "" {
		app.docs.title = "Gjallarhorn API"
	}
	if app.docs.version == "" {
		app.docs.version = "0.1.0"
	}
	// One-time startup allocation on the process heap (lives as long as the app).
	spec := strings.concatenate({app.docs.path, "/openapi.json"}, context.allocator)
	get(app, app.docs.path, docs_page_handler)
	get(app, spec, openapi_spec_handler)
}

openapi_spec_handler :: proc(b: ^Bifrost) {
	write_response(b, 200, "application/json", openapi_spec(b._app, context.temp_allocator))
}

docs_page_handler :: proc(b: ^Bifrost) {
	html(b, 200, docs_html(b._app, context.temp_allocator))
}

// ---------------------------------------------------------------------------
// The OpenAPI document
// ---------------------------------------------------------------------------

// openapi_spec builds a minimal but valid OpenAPI 3.0.3 document from app.routes.
// Routes are grouped by path (in first-seen order) with one operation per method;
// HEAD/OPTIONS are elided (HEAD is implicit off GET, OPTIONS is the cors rune).
openapi_spec :: proc(app: ^App, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `{"openapi":"3.0.3","info":{"title":`)
	json_escape(&sb, app.docs.title != "" ? app.docs.title : "Gjallarhorn API")
	strings.write_string(&sb, `,"version":`)
	json_escape(&sb, app.docs.version != "" ? app.docs.version : "0.1.0")
	if app.docs.description != "" {
		strings.write_string(&sb, `,"description":`)
		json_escape(&sb, app.docs.description)
	}
	strings.write_string(&sb, `},"paths":{`)

	// Group by OpenAPI path template, preserving first-seen order for stable output.
	order := make([dynamic]string, allocator)
	groups := make(map[string][dynamic]Route, allocator)
	for r in app.routes {
		if r.method == .Head || r.method == .Options {
			continue
		}
		tmpl := openapi_path(r.path, allocator)
		g, seen := groups[tmpl]
		if !seen {
			append(&order, tmpl)
			g = make([dynamic]Route, allocator) // else a nil array appends on the heap
		}
		append(&g, r)
		groups[tmpl] = g
	}

	for tmpl, i in order {
		if i > 0 {
			strings.write_byte(&sb, ',')
		}
		json_escape(&sb, tmpl)
		strings.write_string(&sb, `:{`)
		for r, j in groups[tmpl] {
			if j > 0 {
				strings.write_byte(&sb, ',')
			}
			doc, has_doc := app.route_docs[route_key(r.method, r.path, allocator)]
			write_operation(&sb, r, doc, has_doc)
		}
		strings.write_byte(&sb, '}')
	}

	strings.write_string(&sb, "}}")
	return strings.to_string(sb)
}

// write_operation emits one method's operation object: summary, path parameters,
// a request-body schema and a 200-response schema (when described), and the
// responses we can be sure of.
@(private)
write_operation :: proc(sb: ^strings.Builder, r: Route, doc: Route_Doc, has_doc: bool) {
	json_escape(sb, strings.to_lower(method_name(r.method), context.temp_allocator)) // method key
	strings.write_string(sb, `:{"summary":`)
	summary := has_doc && doc.summary != "" ? doc.summary : fmt.tprintf("%s %s", method_name(r.method), r.path)
	json_escape(sb, summary)

	params := path_param_names(r.path)
	if len(params) > 0 {
		strings.write_string(sb, `,"parameters":[`)
		for p, k in params {
			if k > 0 {
				strings.write_byte(sb, ',')
			}
			strings.write_string(sb, `{"name":`)
			json_escape(sb, p)
			strings.write_string(sb, `,"in":"path","required":true,"schema":{"type":"string"}}`)
		}
		strings.write_byte(sb, ']')
	}

	if has_doc && doc.request != nil {
		strings.write_string(sb, `,"requestBody":{"required":true,"content":{"application/json":{"schema":`)
		write_schema(sb, doc.request)
		strings.write_string(sb, `}}}`)
	}

	strings.write_string(sb, `,"responses":{"200":{"description":"OK"`)
	if has_doc && doc.response != nil {
		strings.write_string(sb, `,"content":{"application/json":{"schema":`)
		write_schema(sb, doc.response)
		strings.write_string(sb, `}}`)
	}
	strings.write_byte(sb, '}') // close 200
	if r.ward != nil {
		strings.write_string(sb, `,"401":{"description":"Unauthorized — this route is guarded by a ward"}`)
	}
	strings.write_string(sb, "}}") // close responses + operation
}

// openapi_path turns the router's ":id" segments into OpenAPI's "{id}" templating.
openapi_path :: proc(path: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(path, ":") {
		return path
	}
	segs := strings.split(path, "/", allocator)
	for seg, i in segs {
		if len(seg) > 0 && seg[0] == ':' {
			segs[i] = strings.concatenate({"{", seg[1:], "}"}, allocator)
		}
	}
	return strings.join(segs, "/", allocator)
}

// path_param_names lists the :param names in a route pattern, in order.
path_param_names :: proc(path: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for seg in strings.split(path, "/", allocator) {
		if len(seg) > 0 && seg[0] == ':' {
			append(&out, seg[1:])
		}
	}
	return out[:]
}

// method_name is the wire spelling of a Method — the inverse of parse_method.
method_name :: proc(m: Method) -> string {
	switch m {
	case .Get:
		return "GET"
	case .Post:
		return "POST"
	case .Put:
		return "PUT"
	case .Patch:
		return "PATCH"
	case .Delete:
		return "DELETE"
	case .Head:
		return "HEAD"
	case .Options:
		return "OPTIONS"
	}
	return "GET"
}

// ---------------------------------------------------------------------------
// Reflection: an Odin type -> JSON Schema + an example value
//
// These walk a typeid the same way Mímir does (reflect.struct_fields_zipped),
// mapping the framework's column types the way sql_type does — so a struct used
// as a model documents itself. What json.marshal would emit is what we describe:
// property names honour a `json:"name"` tag, else the field name.
// ---------------------------------------------------------------------------

// schema_json renders a type as a standalone OpenAPI Schema Object string.
schema_json :: proc(id: typeid, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	write_schema(&sb, id)
	return strings.to_string(sb)
}

// example_json renders a filled-in example value for a type (pretty-printed),
// used for the "Try it" request body and the response sample.
example_json :: proc(id: typeid, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	write_example(&sb, id, 0)
	return strings.to_string(sb)
}

@(private)
write_schema :: proc(sb: ^strings.Builder, id: typeid, nullable := false) {
	// Maybe(T) is a single-variant union: describe T, marked nullable.
	base := runtime.type_info_base(type_info_of(id))
	if u, ok := base.variant.(runtime.Type_Info_Union); ok && len(u.variants) == 1 {
		write_schema(sb, u.variants[0].id, true)
		return
	}
	strings.write_byte(sb, '{')
	write_type_body(sb, id)
	if nullable {
		strings.write_string(sb, `,"nullable":true`)
	}
	strings.write_byte(sb, '}')
}

// write_type_body writes the "type"/"items"/"properties" of a schema, without the
// enclosing braces (so write_schema can splice in "nullable").
@(private)
write_type_body :: proc(sb: ^strings.Builder, id: typeid) {
	// The framework's special column types, mapped the way sql_type maps them.
	switch id {
	case time.Time:
		strings.write_string(sb, `"type":"string","format":"date-time"`)
		return
	case []u8:
		strings.write_string(sb, `"type":"string","format":"byte"`)
		return
	case Uuid:
		strings.write_string(sb, `"type":"string","format":"uuid"`)
		return
	case Json:
		strings.write_string(sb, `"type":"object"`)
		return
	}
	#partial switch v in runtime.type_info_base(type_info_of(id)).variant {
	case runtime.Type_Info_Integer:
		strings.write_string(sb, `"type":"integer"`)
	case runtime.Type_Info_Float:
		strings.write_string(sb, `"type":"number"`)
	case runtime.Type_Info_Boolean:
		strings.write_string(sb, `"type":"boolean"`)
	case runtime.Type_Info_String:
		strings.write_string(sb, `"type":"string"`)
	case runtime.Type_Info_Slice:
		strings.write_string(sb, `"type":"array","items":`)
		write_schema(sb, v.elem.id)
	case runtime.Type_Info_Array:
		strings.write_string(sb, `"type":"array","items":`)
		write_schema(sb, v.elem.id)
	case runtime.Type_Info_Dynamic_Array:
		strings.write_string(sb, `"type":"array","items":`)
		write_schema(sb, v.elem.id)
	case runtime.Type_Info_Struct:
		write_struct_schema(sb, id)
	case:
		strings.write_string(sb, `"type":"string"`) // honest fallback
	}
}

@(private)
write_struct_schema :: proc(sb: ^strings.Builder, id: typeid) {
	strings.write_string(sb, `"type":"object","properties":{`)
	first := true
	for f in reflect.struct_fields_zipped(id) {
		name := json_field_name(f)
		if name == "-" {
			continue
		}
		if !first {
			strings.write_byte(sb, ',')
		}
		first = false
		json_escape(sb, name)
		strings.write_byte(sb, ':')
		write_schema(sb, f.type.id)
	}
	strings.write_byte(sb, '}')
}

@(private)
write_example :: proc(sb: ^strings.Builder, id: typeid, indent: int) {
	switch id {
	case time.Time:
		strings.write_string(sb, `"2026-01-01T00:00:00Z"`)
		return
	case []u8:
		strings.write_string(sb, `""`)
		return
	case Uuid:
		strings.write_string(sb, `"00000000-0000-0000-0000-000000000000"`)
		return
	case Json:
		strings.write_string(sb, "{}")
		return
	}
	base := runtime.type_info_base(type_info_of(id))
	if u, ok := base.variant.(runtime.Type_Info_Union); ok && len(u.variants) == 1 {
		write_example(sb, u.variants[0].id, indent)
		return
	}
	#partial switch v in base.variant {
	case runtime.Type_Info_Integer:
		strings.write_string(sb, "0")
	case runtime.Type_Info_Float:
		strings.write_string(sb, "0")
	case runtime.Type_Info_Boolean:
		strings.write_string(sb, "false")
	case runtime.Type_Info_String:
		strings.write_string(sb, `"string"`)
	case runtime.Type_Info_Slice:
		strings.write_byte(sb, '[')
		write_example(sb, v.elem.id, indent)
		strings.write_byte(sb, ']')
	case runtime.Type_Info_Array:
		strings.write_byte(sb, '[')
		write_example(sb, v.elem.id, indent)
		strings.write_byte(sb, ']')
	case runtime.Type_Info_Dynamic_Array:
		strings.write_byte(sb, '[')
		write_example(sb, v.elem.id, indent)
		strings.write_byte(sb, ']')
	case runtime.Type_Info_Struct:
		write_struct_example(sb, id, indent)
	case:
		strings.write_string(sb, "null")
	}
}

@(private)
write_struct_example :: proc(sb: ^strings.Builder, id: typeid, indent: int) {
	strings.write_string(sb, "{\n")
	first := true
	for f in reflect.struct_fields_zipped(id) {
		name := json_field_name(f)
		if name == "-" {
			continue
		}
		if !first {
			strings.write_string(sb, ",\n")
		}
		first = false
		write_indent(sb, indent + 1)
		json_escape(sb, name)
		strings.write_string(sb, ": ")
		write_example(sb, f.type.id, indent + 1)
	}
	strings.write_byte(sb, '\n')
	write_indent(sb, indent)
	strings.write_byte(sb, '}')
}

@(private)
write_indent :: proc(sb: ^strings.Builder, indent: int) {
	for _ in 0 ..< indent {
		strings.write_string(sb, "  ")
	}
}

// json_field_name is the key json.marshal would use for a struct field: a
// `json:"name"` tag if present (its first comma-part), otherwise the field name.
@(private)
json_field_name :: proc(f: reflect.Struct_Field) -> string {
	if tag := reflect.struct_tag_get(f.tag, "json"); tag != "" {
		name := tag
		if comma := strings.index_byte(tag, ','); comma >= 0 {
			name = tag[:comma]
		}
		if name != "" {
			return name
		}
	}
	return f.name
}

// json_escape writes s as a quoted, escaped JSON string. We build the spec by hand
// (rather than marshalling nested maps), so this is the one string-escape choke.
@(private)
json_escape :: proc(sb: ^strings.Builder, s: string) {
	strings.write_byte(sb, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':
			strings.write_string(sb, `\"`)
		case '\\':
			strings.write_string(sb, `\\`)
		case '\n':
			strings.write_string(sb, `\n`)
		case '\r':
			strings.write_string(sb, `\r`)
		case '\t':
			strings.write_string(sb, `\t`)
		case:
			if c < 0x20 {
				fmt.sbprintf(sb, `\u%04x`, int(c))
			} else {
				strings.write_byte(sb, c)
			}
		}
	}
	strings.write_byte(sb, '"')
}

// ---------------------------------------------------------------------------
// The HTML page — woven by Loom, with a live "Try it"
// ---------------------------------------------------------------------------

// docs_html builds the endpoint context and weaves DOCS_TEMPLATE — the docs page
// is a Loom template like any other, just carried in the binary rather than on disk.
docs_html :: proc(app: ^App, allocator := context.temp_allocator) -> string {
	eps := make([dynamic]Value, allocator)
	for r in app.routes {
		if r.method == .Head || r.method == .Options {
			continue
		}
		doc, has_doc := app.route_docs[route_key(r.method, r.path, allocator)]

		params := make([dynamic]Value, allocator)
		for p in path_param_names(r.path, allocator) {
			append(&params, p)
		}

		has_body := r.method == .Post || r.method == .Put || r.method == .Patch
		req_example := "{}"
		if has_doc && doc.request != nil {
			req_example = example_json(doc.request, allocator)
		}
		has_res := has_doc && doc.response != nil
		res_example := has_res ? example_json(doc.response, allocator) : ""

		append(
			&eps,
			warp(
				{"method", method_name(r.method)},
				{"path", r.path},
				{"cls", strings.to_lower(method_name(r.method), allocator)},
				{"guarded", r.ward != nil},
				{"summary", has_doc ? doc.summary : ""},
				{"params", params[:]},
				{"has_body", has_body},
				{"req_example", req_example},
				{"has_res", has_res},
				{"res_example", res_example},
				allocator = allocator,
			),
		)
	}
	ctx := warp(
		{"title", app.docs.title != "" ? app.docs.title : "Gjallarhorn API"},
		{"version", app.docs.version != "" ? app.docs.version : "0.1.0"},
		{"description", app.docs.description},
		{"has_description", app.docs.description != ""},
		{"spec_url", strings.concatenate({app.docs.path != "" ? app.docs.path : "/api-docs", "/openapi.json"}, allocator)},
		{"count", len(eps)},
		{"endpoints", eps[:]},
		allocator = allocator,
	)
	out, err := weave(DOCS_TEMPLATE, ctx, allocator)
	if err != .None {
		return "<!doctype html><title>docs</title><p>docs template error</p>"
	}
	return out
}

// DOCS_TEMPLATE is the Loom source for the docs page. Self-contained (inline CSS
// and a little vanilla JS, no external assets), autoescaped by Loom like any
// template. Note it uses only single "{" in CSS/JS — never "{{"/"{%"/"{#", and no
// adjacent "}}" — so nothing collides with Loom's tags.
@(private)
DOCS_TEMPLATE :: `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title }} — API reference</title>
<style>
:root { --bg:#0d1117; --card:#161b22; --card2:#0b0f14; --line:#30363d; --fg:#e6edf3; --muted:#8b949e; --accent:#58a6ff; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.55 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif; }
.wrap { max-width:940px; margin:0 auto; padding:48px 24px 96px; }
h1 { margin:0 0 6px; font-size:30px; letter-spacing:-.02em; }
h4 { margin:16px 0 8px; font-size:12px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); }
.ver { color:var(--muted); font-size:13px; }
.desc { color:var(--muted); margin:14px 0 0; }
.spec-link { display:inline-block; margin-top:18px; color:var(--accent); text-decoration:none; font-size:14px; }
.spec-link:hover { text-decoration:underline; }
.count { color:var(--muted); font-size:12px; margin:34px 0 12px; text-transform:uppercase; letter-spacing:.09em; }
.route { background:var(--card); border:1px solid var(--line); border-radius:10px; margin-bottom:8px; overflow:hidden; }
.head { display:flex; align-items:center; gap:14px; width:100%; padding:12px 16px; background:none; border:0; color:var(--fg); cursor:pointer; text-align:left; font:inherit; }
.head:hover { background:rgba(255,255,255,.03); }
.badge { font:700 12px/1 ui-monospace,SFMono-Regular,Menlo,monospace; padding:7px 10px; border-radius:6px; min-width:66px; text-align:center; color:#fff; }
.badge.get { background:#1f6feb; }
.badge.post { background:#238636; }
.badge.put { background:#9e6a03; }
.badge.patch { background:#8957e5; }
.badge.delete { background:#da3633; }
.path { font:14px/1 ui-monospace,SFMono-Regular,Menlo,monospace; }
.sum { margin-left:auto; color:var(--muted); font-size:13px; }
.lock { color:var(--muted); font-size:12px; margin-left:8px; }
.panel { padding:4px 16px 18px; border-top:1px solid var(--line); }
label { display:block; margin:6px 0; font-size:13px; color:var(--muted); }
label input { display:block; width:100%; margin-top:4px; padding:8px 10px; background:var(--card2); border:1px solid var(--line); border-radius:6px; color:var(--fg); font:13px ui-monospace,Menlo,monospace; }
textarea { width:100%; padding:10px; background:var(--card2); border:1px solid var(--line); border-radius:6px; color:var(--fg); font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; resize:vertical; }
pre { margin:0; padding:12px; background:var(--card2); border:1px solid var(--line); border-radius:6px; overflow:auto; font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; }
.exec { margin-top:14px; padding:9px 18px; background:var(--accent); color:#0d1117; border:0; border-radius:6px; font:600 14px/1 inherit; cursor:pointer; }
.exec:hover { filter:brightness(1.08); }
.status { margin:10px 0 8px; font:600 13px ui-monospace,Menlo,monospace; }
footer { margin-top:48px; color:var(--muted); font-size:12px; }
footer a { color:var(--accent); text-decoration:none; }
[hidden] { display:none; }
</style>
</head>
<body>
<div class="wrap">
<h1>{{ title }}</h1>
<div class="ver">v{{ version }}</div>
{% if has_description %}<p class="desc">{{ description }}</p>{% endif %}
<a class="spec-link" href="{{ spec_url }}">↧ OpenAPI spec — openapi.json</a>
<div class="count">{{ count }} endpoints</div>
{% for e in endpoints %}
<div class="route" data-method="{{ e.method }}" data-path="{{ e.path }}">
<button type="button" class="head" data-toggle>
<span class="badge {{ e.cls }}">{{ e.method }}</span>
<span class="path">{{ e.path }}</span>
{% if e.summary %}<span class="sum">{{ e.summary }}</span>{% endif %}
{% if e.guarded %}<span class="lock">🔒 guarded</span>{% endif %}
</button>
<div class="panel" hidden>
{% if e.params %}<h4>Path parameters</h4>{% for p in e.params %}<label>{{ p }}<input data-param="{{ p }}" placeholder="{{ p }}"></label>{% endfor %}{% endif %}
{% if e.has_body %}<h4>Request body</h4><textarea data-body rows="8">{{ e.req_example }}</textarea>{% endif %}
<button type="button" class="exec" data-exec>Execute</button>
<div class="result" hidden><h4>Response</h4><div class="status"></div><pre class="respbody"></pre></div>
{% if e.has_res %}<h4>Response schema — 200 (example)</h4><pre>{{ e.res_example }}</pre>{% endif %}
</div>
</div>
{% else %}
<p class="desc">No routes registered yet.</p>
{% endfor %}
<footer>ᚷ Generated by <a href="https://github.com/Lvcky-gg/Gjallarhorn">Gjallarhorn</a> · woven by Loom</footer>
</div>
<script>
document.querySelectorAll('[data-toggle]').forEach(function (btn) {
  btn.addEventListener('click', function () {
    var panel = btn.parentElement.querySelector('.panel');
    panel.hidden = !panel.hidden;
  });
});
document.querySelectorAll('[data-exec]').forEach(function (btn) {
  btn.addEventListener('click', async function () {
    var route = btn.closest('.route');
    var method = route.dataset.method;
    var path = route.dataset.path;
    route.querySelectorAll('[data-param]').forEach(function (inp) {
      path = path.replace(':' + inp.dataset.param, encodeURIComponent(inp.value || ''));
    });
    var opts = { method: method, headers: {} };
    var body = route.querySelector('[data-body]');
    if (body) {
      opts.body = body.value;
      opts.headers['Content-Type'] = 'application/json';
    }
    var result = route.querySelector('.result');
    var statusEl = route.querySelector('.status');
    var bodyEl = route.querySelector('.respbody');
    result.hidden = false;
    statusEl.textContent = 'requesting…';
    bodyEl.textContent = '';
    try {
      var res = await fetch(path, opts);
      statusEl.textContent = res.status + ' ' + res.statusText;
      var text = await res.text();
      try {
        bodyEl.textContent = JSON.stringify(JSON.parse(text), null, 2);
      } catch (e) {
        bodyEl.textContent = text;
      }
    } catch (e) {
      statusEl.textContent = 'request failed';
      bodyEl.textContent = String(e);
    }
  });
});
</script>
</body>
</html>`
