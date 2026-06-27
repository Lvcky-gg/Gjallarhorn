package gjallarhorn

// loom.odin — the bridge between gjallarhorn's HTTP cycle and Loom, the
// templating engine. The engine itself now lives in the `loom` subpackage
// (gjallarhorn/loom/); see its loom.odin for the dialect and design notes.
//
// Loom can't import gjallarhorn (that would be a cycle: gjallarhorn -> loom),
// so the request/response glue — rendering a template to an HTTP response and
// the directory mounts hail serves — stays here in the parent package. The
// re-exports below let the rest of gjallarhorn (and its tests) keep referring
// to the core types and `weave` unqualified.

import "core:os"
import "loom"

// Re-exports of the engine's public surface.
Value :: loom.Value
Warp :: loom.Warp
Binding :: loom.Binding
Loom_Error :: loom.Loom_Error
warp :: loom.warp
warp_of :: loom.warp_of
value_of :: loom.value_of
list :: loom.list
weave :: loom.weave
weave_file :: loom.weave_file
loaded_parse_count :: loom.loaded_parse_count

html :: proc(b: ^Bifrost, status: int, body: string) {
	write_response(b, status, "text/html; charset=utf-8", body)
}

render :: proc(b: ^Bifrost, path: string, ctx: Warp) {
	out, werr := weave_file(path, ctx, context.temp_allocator)
	if werr == .Missing_Template {
		text(b, 500, "template not found")
		return
	}
	if werr != .None {
		text(b, 500, "template error")
		return
	}
	html(b, 200, out)
}

Provider :: proc(b: ^Bifrost) -> Warp

Loom_Mount :: struct {
	url_prefix: string,
	dir:        string,
	provider:   Provider, // may be nil -> rendered with an empty context
}

hail_loom :: proc(app: ^App, url_prefix: string, dir: string, provider: Provider) {
	append(&app.looms, Loom_Mount{url_prefix = url_prefix, dir = dir, provider = provider})
}

serve_loom :: proc(b: ^Bifrost, mount: Loom_Mount) -> bool {
	target, within := safe_target(mount.dir, mount.url_prefix, b.path)
	if !within {
		text(b, 403, "403 forbidden")
		return true
	}
	if os.is_directory(target) {
		text(b, 403, "403 forbidden")
		return true
	}
	if !os.exists(target) {
		return false // not found — let dispatch_route 404 it
	}

	ctx: Warp
	if mount.provider != nil {
		ctx = mount.provider(b)
	}
	out, werr := weave_file(target, ctx, context.temp_allocator)
	if werr != .None {
		text(b, 500, "template error")
		return true
	}
	html(b, 200, out)
	return true
}
