package gjallarhorn

// static.odin — hail + static file serving. The security checkpoint for this
// feature is path traversal: a resolved path must never escape the mount root.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
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
// static_cache_control is the Cache-Control sent with every static file. The
// default lets browsers and shared caches hold assets for an hour; override it
// (e.g. "public, max-age=31536000, immutable" for content-hashed filenames).
static_cache_control := "public, max-age=3600"

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

	// Precompressed gzip (nginx's `gzip_static`): if a sibling <file>.gz exists,
	// note it in Vary and serve it to clients that accept gzip. Odin core ships no
	// gzip *compressor*, so compression is done ahead of time, not per request.
	serve_path := target
	encoding := ""
	gz := strings.concatenate({target, ".gz"}, context.temp_allocator)
	has_gz := os.exists(gz) && !os.is_directory(gz)
	if has_gz && accepts_gzip(b) {
		serve_path = gz
		encoding = "gzip"
	}

	info, serr := os.stat(serve_path, context.temp_allocator)
	if serr != nil {
		return false // not found — let dispatch_route 404 it
	}

	// Validators from the served file's size + mtime. Content-Type comes from the
	// *original* name — a .gz is a transport encoding, not a media type.
	etag := file_etag(info)
	last_mod := http_date(info.modification_time)
	ctype := content_type_for(filepath.ext(target))

	set_header(b, "ETag", etag)
	set_header(b, "Last-Modified", last_mod)
	set_header(b, "Cache-Control", static_cache_control)
	if has_gz {
		set_header(b, "Vary", "Accept-Encoding") // caches must key on the encoding
	}

	// A still-fresh conditional request gets 304 and no body — the win that stops
	// re-sending unchanged assets.
	if static_not_modified(b, etag, last_mod) {
		write_response(b, 304, ctype, "")
		return true
	}

	data, err := os.read_entire_file(serve_path, context.temp_allocator)
	if err != nil {
		return false
	}
	if encoding != "" {
		set_header(b, "Content-Encoding", encoding)
	}
	write_response(b, 200, ctype, string(data))
	return true
}

// accepts_gzip reports whether the client's Accept-Encoding admits gzip. (A
// `;q=0` refusal is not parsed — rare, and the cost is only skipping compression.)
accepts_gzip :: proc(b: ^Bifrost) -> bool {
	ae, ok := header(b, "accept-encoding")
	return ok && strings.contains(ae, "gzip")
}

// file_etag builds a strong ETag from a file's size and mtime — it changes iff
// the bytes could have, and needs no read of the content.
file_etag :: proc(info: os.File_Info) -> string {
	return fmt.tprintf("\"%x-%x\"", info.size, info.modification_time._nsec)
}

// static_not_modified applies the conditional-request rules: an If-None-Match
// that lists our ETag (or `*`) wins; failing that, an If-Modified-Since equal to
// the Last-Modified we'd send. ETag takes precedence, per RFC 7232.
static_not_modified :: proc(b: ^Bifrost, etag, last_mod: string) -> bool {
	if inm, ok := header(b, "if-none-match"); ok {
		return inm == "*" || strings.contains(inm, etag)
	}
	if ims, ok := header(b, "if-modified-since"); ok {
		return ims == last_mod
	}
	return false
}

// http_date formats a Time as an RFC 7231 IMF-fixdate (always GMT), the format
// HTTP dates use: "Sun, 06 Nov 1994 08:49:37 GMT". Time is UTC nanoseconds, so no
// zone conversion is needed.
http_date :: proc(t: time.Time) -> string {
	@(static) days := [?]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	@(static) mons := [?]string {
		"Jan",
		"Feb",
		"Mar",
		"Apr",
		"May",
		"Jun",
		"Jul",
		"Aug",
		"Sep",
		"Oct",
		"Nov",
		"Dec",
	}
	y, mo, d := time.date(t)
	hh, mm, ss := time.clock_from_time(t)
	return fmt.tprintf(
		"%s, %02d %s %04d %02d:%02d:%02d GMT",
		days[int(time.weekday(t))],
		d,
		mons[int(mo) - 1],
		y,
		hh,
		mm,
		ss,
	)
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
