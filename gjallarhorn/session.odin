package gjallarhorn

// session.odin — signed-cookie sessions (GH-051). The session is a small
// string->string map that rides in a cookie the client holds; the server keeps
// no state. To stop a client from forging or editing it, the cookie carries an
// HMAC-SHA256 tag over the payload, keyed by App.secret (see app.odin). On read
// the tag is checked in constant time; any mismatch — a flipped byte, a swapped
// payload — is treated as no session at all.
//
// Cookie shape:  base64url(json) "." base64url(hmac_sha256(base64url(json)))
//
// Values live in the request's temp arena, so a session is per-request: read it,
// mutate it, and the response carries the updated cookie. session_set rewrites
// the single session cookie each call, so repeated sets within one request
// accumulate rather than clobber.

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"

// SESSION_COOKIE is the cookie name the session rides in.
SESSION_COOKIE :: "gsession"

// session_get reads a value from the session, loading and verifying the cookie
// on first access. A missing or tampered cookie reads as an empty session.
session_get :: proc(b: ^Bifrost, key: string) -> (string, bool) {
	session_load(b)
	v, ok := b._session[key]
	return v, ok
}

// session_set stores a value and refreshes the signed session cookie on the
// response, replacing any session cookie queued earlier this request.
session_set :: proc(b: ^Bifrost, key, value: string) {
	session_load(b)
	b._session[key] = value
	session_flush(b)
}

// session_clear empties the session and expires the cookie on the client.
session_clear :: proc(b: ^Bifrost) {
	session_load(b)
	clear(&b._session)
	session_drop_cookie(b)
	set_cookie(
		b,
		SESSION_COOKIE,
		"",
		Cookie_Options{path = "/", http_only = true, same_site = .Lax, max_age = 0},
	)
}

// ---------------------------------------------------------------------------
// internals
// ---------------------------------------------------------------------------

// session_load parses and verifies the request's session cookie once, caching
// the result on the Bifrost. An absent or invalid cookie yields an empty map.
session_load :: proc(b: ^Bifrost) {
	if b._session_loaded {
		return
	}
	b._session_loaded = true
	b._session = make(map[string]string, context.temp_allocator)

	raw, ok := cookie(b, SESSION_COOKIE)
	if !ok {
		return
	}
	if values, valid := session_unseal(raw, session_key(b)); valid {
		b._session = values
	}
}

// session_flush re-encodes the session into one signed cookie, dropping any
// earlier session cookie so only the latest is sent.
session_flush :: proc(b: ^Bifrost) {
	session_drop_cookie(b)
	set_cookie(
		b,
		SESSION_COOKIE,
		session_seal(b._session, session_key(b)),
		Cookie_Options{path = "/", http_only = true, same_site = .Lax},
	)
}

// session_drop_cookie removes any queued Set-Cookie for the session, so flush
// and clear never emit duplicate session cookies.
session_drop_cookie :: proc(b: ^Bifrost) {
	if b.cookies == nil {
		return
	}
	prefix := strings.concatenate({SESSION_COOKIE, "="}, context.temp_allocator)
	kept := make([dynamic]string, 0, len(b.cookies), context.temp_allocator)
	for c in b.cookies {
		if !strings.has_prefix(c, prefix) {
			append(&kept, c)
		}
	}
	b.cookies = kept
}

// session_key is App.secret when set, else the insecure default (new() warns).
// Tolerates a nil _app so a Bifrost built in tests still signs.
session_key :: proc(b: ^Bifrost) -> string {
	if b._app != nil && b._app.secret != "" {
		return b._app.secret
	}
	return DEFAULT_SECRET
}

// session_seal serializes values to JSON, base64url-encodes it, and appends a
// base64url HMAC tag: "<payload>.<tag>".
session_seal :: proc(values: map[string]string, key: string) -> string {
	payload, _ := json.marshal(values, {}, context.temp_allocator)
	p64 := base64.encode(payload, base64.ENC_URL_TABLE, context.temp_allocator)

	tag: [32]byte
	hmac.sum(.SHA256, tag[:], transmute([]byte)p64, transmute([]byte)key)
	t64 := base64.encode(tag[:], base64.ENC_URL_TABLE, context.temp_allocator)

	return strings.concatenate({p64, ".", t64}, context.temp_allocator)
}

// session_unseal splits "<payload>.<tag>", verifies the tag against `key` in
// constant time, and decodes the payload. valid is false on any tamper or
// malformed input — the caller then treats it as no session.
session_unseal :: proc(raw, key: string) -> (values: map[string]string, valid: bool) {
	dot := strings.index_byte(raw, '.')
	if dot < 0 {
		return nil, false
	}
	p64 := raw[:dot]
	t64 := raw[dot + 1:]

	tag, terr := base64.decode(t64, base64.DEC_URL_TABLE, nil, context.temp_allocator)
	if terr != nil {
		return nil, false
	}
	if !hmac.verify(.SHA256, tag, transmute([]byte)p64, transmute([]byte)key) {
		return nil, false
	}

	payload, perr := base64.decode(p64, base64.DEC_URL_TABLE, nil, context.temp_allocator)
	if perr != nil {
		return nil, false
	}
	m := make(map[string]string, context.temp_allocator)
	if json.unmarshal(payload, &m, allocator = context.temp_allocator) != nil {
		return nil, false
	}
	return m, true
}
