package gjallarhorn

// multipart.odin — multipart/form-data request bodies (file uploads). A browser
// posting a form with <input type=file> sends multipart/form-data instead of
// urlencoded: parts separated by a boundary, each with its own headers. This
// decodes it binary-safely (file bytes may contain anything, including CRLF and
// boundary-looking runs) into text fields and uploaded files.
//
// Handlers reach it through the same form() they already use — a multipart body's
// text fields land in the form map, so CSRF tokens and ordinary inputs work
// unchanged — plus files()/upload() for the file parts:
//
//   name := gh.form(b)["title"]              // text field, either encoding
//   if f, ok := gh.upload(b, "avatar"); ok { // uploaded file
//       // f.filename, f.content_type, f.data ([]u8)
//   }

import "core:bytes"
import "base:runtime"
import "core:strings"

// Upload is one file part of a multipart/form-data body. data points into the
// request body (temp arena), valid for the life of the request.
Upload :: struct {
	filename:     string,
	content_type: string,
	data:         []u8,
}

// MAX_MULTIPART_PARTS caps how many parts we'll split a body into, so a body of
// nothing but boundaries can't spin. The body itself is already size-capped at
// read time (max_body), bounding total upload size.
MAX_MULTIPART_PARTS :: 4096

// files returns every uploaded file in a multipart/form-data body, keyed by the
// form field name. Empty for a urlencoded or bodyless request.
files :: proc(b: ^Bifrost) -> map[string]Upload {
	load_form(b)
	return b._files
}

// upload returns a single uploaded file by field name, ok=false if absent.
upload :: proc(b: ^Bifrost, name: string) -> (Upload, bool) {
	load_form(b)
	f, ok := b._files[name]
	return f, ok
}

// load_form decodes the request body once, caching the fields and files on the
// Bifrost. multipart/form-data splits into fields + files; anything else is
// treated as urlencoded (the historic form() behaviour). Idempotent, so form()
// and files() can both trigger it and the body is parsed a single time.
load_form :: proc(b: ^Bifrost, allocator := context.temp_allocator) {
	if b._form_parsed {
		return
	}
	b._form_parsed = true
	b._files = make(map[string]Upload, allocator)

	ct, _ := header(b, "content-type")
	if boundary, ok := multipart_boundary(ct); ok {
		b._form, b._files = parse_multipart(b.body, boundary, allocator)
		return
	}
	b._form = parse_query(b.body_text, allocator)
}

// multipart_boundary pulls the boundary out of a `multipart/form-data; boundary=…`
// Content-Type (the boundary may be quoted). ok=false for any other media type.
multipart_boundary :: proc(content_type: string) -> (string, bool) {
	ct := strings.trim_space(content_type)
	semi := strings.index_byte(ct, ';')
	if semi < 0 {
		return "", false
	}
	if !strings.equal_fold(strings.trim_space(ct[:semi]), "multipart/form-data") {
		return "", false
	}
	for p in strings.split(ct[semi + 1:], ";", context.temp_allocator) {
		kv := strings.trim_space(p)
		eq := strings.index_byte(kv, '=')
		if eq < 0 {
			continue
		}
		if strings.equal_fold(strings.trim_space(kv[:eq]), "boundary") {
			val := strings.trim(strings.trim_space(kv[eq + 1:]), "\"")
			if val == "" {
				return "", false
			}
			return val, true
		}
	}
	return "", false
}

// parse_multipart splits a multipart/form-data body into text fields and files.
// It works on raw bytes so a file's contents are preserved exactly. The part
// separator is CRLF + "--" + boundary (RFC 7578 / 2046); we prepend a CRLF so the
// leading boundary, which has none, matches the same separator, then split on it.
parse_multipart :: proc(
	body: []u8,
	boundary: string,
	allocator: runtime.Allocator,
) -> (
	map[string]string,
	map[string]Upload,
) {
	fields := make(map[string]string, allocator)
	uploads := make(map[string]Upload, allocator)

	sep_str := strings.concatenate({"\r\n--", boundary}, context.temp_allocator)
	sep := transmute([]u8)sep_str

	prefixed := make([]u8, 2 + len(body), context.temp_allocator)
	prefixed[0] = '\r'
	prefixed[1] = '\n'
	copy(prefixed[2:], body)

	// segs[0] is the preamble (empty when well-formed); each later seg is a part,
	// until one beginning with "--" — the closing "--boundary--" delimiter.
	segs := bytes.split(prefixed, sep, context.temp_allocator)
	crlf2 := "\r\n\r\n"
	for seg, i in segs {
		if i == 0 {
			continue // preamble before the first boundary
		}
		if i > MAX_MULTIPART_PARTS {
			break
		}
		if len(seg) >= 2 && seg[0] == '-' && seg[1] == '-' {
			break // closing boundary
		}
		if len(seg) < 2 {
			continue
		}
		part := seg[2:] // drop the CRLF that ended the boundary line
		hb := bytes.index(part, transmute([]u8)crlf2)
		if hb < 0 {
			continue // no header/body separator — malformed part, skip
		}
		headers := string(part[:hb])
		content := part[hb + 4:]

		name, filename, ctype, has_name, is_file := part_disposition(headers)
		if !has_name {
			continue // a part with no field name isn't addressable; drop it
		}
		if is_file {
			uploads[name] = Upload {
				filename     = filename,
				content_type = ctype,
				data         = content,
			}
		} else {
			fields[name] = string(content)
		}
	}
	return fields, uploads
}

// part_disposition reads a part's header block: the form field name and, if the
// part is a file, its filename and declared Content-Type. is_file is true when a
// filename attribute is present (the RFC signal that the part is an upload).
part_disposition :: proc(
	block: string,
) -> (
	name, filename, content_type: string,
	has_name, is_file: bool,
) {
	for line in strings.split(block, "\r\n", context.temp_allocator) {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		key := strings.trim_space(line[:colon])
		val := strings.trim_space(line[colon + 1:])
		switch {
		case strings.equal_fold(key, "content-disposition"):
			name, has_name = header_param(val, "name")
			filename, is_file = header_param(val, "filename")
		case strings.equal_fold(key, "content-type"):
			content_type = val
		}
	}
	return
}

// header_param extracts a `key=value` attribute from a header value, splitting on
// ';' first so "name" isn't matched inside "filename". The value may be quoted.
// (A ';' inside a quoted filename would split early — rare, and left as a known
// limitation rather than a full RFC 2045 quoted-string parser.)
header_param :: proc(s, key: string) -> (string, bool) {
	for p in strings.split(s, ";", context.temp_allocator) {
		kv := strings.trim_space(p)
		eq := strings.index_byte(kv, '=')
		if eq < 0 {
			continue
		}
		if strings.equal_fold(strings.trim_space(kv[:eq]), key) {
			return strings.trim(strings.trim_space(kv[eq + 1:]), "\""), true
		}
	}
	return "", false
}
