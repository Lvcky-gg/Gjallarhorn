package gjallarhorn

// static.odin — hail + static file serving. The security checkpoint for this
// feature is path traversal: a resolved path must never escape the mount root.

import "core:os"
import "core:strings"
import "core:path/filepath"

// A static mount: serve files from `dir` under URL `url_prefix`.
Static_Mount :: struct {
	url_prefix: string,
	dir:        string,
}

// hail: a GET that serves files from `dir` under `url_prefix`. Two shapes:
//
//   hail(&app, "/static", "./public")             raw files
//   hail(&app, "/pages",  "./templates", provider) files woven by Loom
//
// The four-arg form is hail_loom over in loom.odin. Explicit routes win; mounts
// are tried only when no route matches. Path traversal is clamped in
// safe_target, shared by both serve_static and serve_loom.
hail :: proc{hail_static, hail_loom}

hail_static :: proc(app: ^App, url_prefix: string, dir: string) {
	append(&app.statics, Static_Mount{url_prefix = url_prefix, dir = dir})
}

// under_prefix reports whether `path` falls under `prefix` on a segment
// boundary, so prefix "/static" matches "/static/x" but not "/staticfoo".
under_prefix :: proc(path, prefix: string) -> bool {
		if prefix == "/" {
		return true // root mount: every path is under it
	}
	if path == prefix {
		return true
	}
	return strings.has_prefix(path, strings.concatenate({prefix, "/"}, context.temp_allocator))
}

// serve_static resolves a request path to a file inside the mount directory
// and writes it. Returns false (so the caller can 404) when the file is
// missing. Path traversal is the security checkpoint for this phase: the
// resolved path is cleaned and must stay inside the mount root, otherwise 403.
serve_static :: proc(b: ^Bifrost, mount: Static_Mount) -> bool {
	target, within := safe_target(mount.dir, mount.url_prefix, b.path)
	if !within {
		text(b, 403, "403 forbidden")
		return true
	}

	// Reject directories explicitly; we only serve files.
	if os.is_directory(target) {
		text(b, 403, "403 forbidden")
		return true
	}

	data, err := os.read_entire_file(target, context.temp_allocator)
	if err != nil {
		return false // not found — let dispatch_route 404 it
	}

	write_response(b, 200, content_type_for(filepath.ext(target)), string(data))
	return true
}

// safe_target maps a request path to a cleaned file path inside the mount root,
// defaulting a bare directory request to index.html. `within` is false when the
// path would escape the root — the traversal checkpoint both mounts rely on.
safe_target :: proc(dir, url_prefix, req_path: string) -> (target: string, within: bool) {
	rel := strings.trim_prefix(req_path[len(url_prefix):], "/")
	if rel == "" {
		rel = "index.html"
	}

	root, _ := filepath.clean(dir, context.temp_allocator)
	// Join, then clean: any ".." in `rel` is collapsed here so the containment
	// check below sees the real target, not the literal "../" string.
	joined, _ := filepath.join({root, rel}, context.temp_allocator)
	target, _ = filepath.clean(joined, context.temp_allocator)
	within = within_root(root, target)
	return
}

// within_root: `target` must be the root itself or sit beneath it on a
// separator boundary. Both paths are already cleaned by the caller.
within_root :: proc(root, target: string) -> bool {
	if target == root {
		return true
	}
	return strings.has_prefix(target, strings.concatenate({root, "/"}, context.temp_allocator))
}

content_type_for :: proc(ext: string) -> string {
	switch ext {
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".json":
		return "application/json"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".ico":
		return "image/x-icon"
	case ".txt":
		return "text/plain; charset=utf-8"
	case ".wasm":
		return "application/wasm"
	}
	return "application/octet-stream"
}
