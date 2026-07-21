package gjallarhorn

// openapi.odin — a self-describing docs page, woven by Loom from the routes the
// router already knows. It is opt-in: Config.docs.enabled is false by default, so
// nothing is mounted and nothing costs you until you ask (a public app usually
// wants this off). Flip it on and two GET routes appear:
//
//   {docs.path}                 an HTML page (rendered by Loom) listing endpoints
//   {docs.path}/openapi.json    a minimal OpenAPI 3.0 document
//
// Both are generated from app.routes at *request* time, so they always reflect the
// live route table — register a route and it shows up, no annotations to keep in
// sync. What we can't know without schema annotations (request/response bodies) we
// honestly omit rather than invent: each operation carries its path parameters, a
// 200, and — for a warded route — a 401. This is the same incremental honesty the
// rest of the framework keeps.
//
//   app := gh.new(gh.Config{
//       port = 8091,
//       docs = { enabled = true, title = "My API", version = "1.2.0" },
//   })

import "base:runtime"
import "core:fmt"
import "core:strings"

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
			write_operation(&sb, r, allocator)
		}
		strings.write_byte(&sb, '}')
	}

	strings.write_string(&sb, "}}")
	return strings.to_string(sb)
}

// write_operation emits one method's operation object: a summary, path parameters
// (from :segments), and the responses we can be sure of.
@(private)
write_operation :: proc(sb: ^strings.Builder, r: Route, allocator: runtime.Allocator) {
	json_escape(sb, strings.to_lower(method_name(r.method), allocator)) // method key
	strings.write_string(sb, `:{"summary":`)
	json_escape(sb, fmt.tprintf("%s %s", method_name(r.method), r.path))

	params := path_param_names(r.path, allocator)
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

	strings.write_string(sb, `,"responses":{"200":{"description":"OK"}`)
	if r.ward != nil {
		strings.write_string(sb, `,"401":{"description":"Unauthorized — this route is guarded by a ward"}`)
	}
	strings.write_string(sb, "}}")
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
// The HTML page — woven by Loom
// ---------------------------------------------------------------------------

// docs_html builds the endpoint context and weaves DOCS_TEMPLATE — the docs page
// is a Loom template like any other, just carried in the binary rather than on disk.
docs_html :: proc(app: ^App, allocator := context.temp_allocator) -> string {
	eps := make([dynamic]Value, allocator)
	for r in app.routes {
		if r.method == .Head || r.method == .Options {
			continue
		}
		append(
			&eps,
			warp(
				{"method", method_name(r.method)},
				{"path", r.path},
				{"cls", strings.to_lower(method_name(r.method), allocator)},
				{"guarded", r.ward != nil},
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

// DOCS_TEMPLATE is the Loom source for the docs page. Self-contained (inline CSS,
// no external assets), autoescaped by Loom like any template. Note it uses only
// single "{" in CSS — never "{{"/"{%"/"{#" — so nothing collides with Loom's tags.
@(private)
DOCS_TEMPLATE :: `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title }} — API reference</title>
<style>
:root { --bg:#0d1117; --card:#161b22; --line:#30363d; --fg:#e6edf3; --muted:#8b949e; --accent:#58a6ff; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.55 ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,sans-serif; }
.wrap { max-width:900px; margin:0 auto; padding:48px 24px 80px; }
h1 { margin:0 0 6px; font-size:30px; letter-spacing:-.02em; }
.ver { color:var(--muted); font-size:13px; }
.desc { color:var(--muted); margin:14px 0 0; }
.spec-link { display:inline-block; margin-top:18px; color:var(--accent); text-decoration:none; font-size:14px; }
.spec-link:hover { text-decoration:underline; }
.count { color:var(--muted); font-size:12px; margin:34px 0 12px; text-transform:uppercase; letter-spacing:.09em; }
.route { display:flex; align-items:center; gap:14px; background:var(--card); border:1px solid var(--line); border-radius:10px; padding:12px 16px; margin-bottom:8px; }
.badge { font:700 12px/1 ui-monospace,SFMono-Regular,Menlo,monospace; padding:7px 10px; border-radius:6px; min-width:66px; text-align:center; color:#fff; }
.badge.get { background:#1f6feb; }
.badge.post { background:#238636; }
.badge.put { background:#9e6a03; }
.badge.patch { background:#8957e5; }
.badge.delete { background:#da3633; }
.path { font:14px/1 ui-monospace,SFMono-Regular,Menlo,monospace; }
.lock { margin-left:auto; color:var(--muted); font-size:12px; }
footer { margin-top:48px; color:var(--muted); font-size:12px; }
footer a { color:var(--accent); text-decoration:none; }
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
<div class="route">
<span class="badge {{ e.cls }}">{{ e.method }}</span>
<span class="path">{{ e.path }}</span>
{% if e.guarded %}<span class="lock">🔒 guarded</span>{% endif %}
</div>
{% else %}
<p class="desc">No routes registered yet.</p>
{% endfor %}
<footer>ᚷ Generated by <a href="https://github.com/Lvcky-gg/Gjallarhorn">Gjallarhorn</a> · woven by Loom</footer>
</div>
</body>
</html>`
