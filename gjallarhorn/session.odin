package gjallarhorn

// session.odin — signed-cookie sessions (GH-051). The session is a small
// string->string map that rides in a cookie the client holds; the server keeps
// no state. To stop a client from forging or editing it, the cookie carries an
// HMAC-SHA256 tag over the payload, keyed by App.secret (see app.odin). On read
// the tag is checked in constant time; any mismatch — a flipped byte, a swapped
// payload — is treated as no session at all.
//
// The signed payload is an envelope { exp, data }: `exp` is a unix-seconds
// expiry embedded *inside* the HMAC, so expiry is enforced server-side on read —
// a client can't extend its own session by editing the cookie's Max-Age. The
// cookie also carries Max-Age (rolling, refreshed on every write) and, over
// HTTPS, the Secure flag so it's never sent in cleartext.
//
// Cookie shape:  base64url(json{exp,data}) "." base64url(hmac_sha256(payload))
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
import "core:time"

// SESSION_COOKIE is the cookie name the session rides in.
SESSION_COOKIE :: "gsession"

// SESSION_MAX_AGE is the default session lifetime, in seconds. It sets both the
// cookie's Max-Age and the signed `exp`, and is refreshed on every write, so an
// active session rolls forward and an idle one lapses.
SESSION_MAX_AGE :: 24 * 60 * 60 // 24h

// Session_Envelope is what actually gets signed: the caller's key/value session
// (`data`) plus an absolute expiry (`exp`, unix seconds; 0 = never). Because
// `exp` is inside the HMAC, tampering with it invalidates the whole cookie.
Session_Envelope :: struct {
	exp:  i64,
	data: map[string]string,
}

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

// session_delete removes a single key and refreshes the signed cookie, leaving
// the rest of the session intact — e.g. logout dropping just the auth key.
session_delete :: proc(b: ^Bifrost, key: string) {
	session_load(b)
	delete_key(&b._session, key)
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
		Cookie_Options {
			path = "/",
			http_only = true,
			same_site = .Lax,
			secure = b.ssl != nil,
			max_age = 0,
		},
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
	exp := time.to_unix_seconds(time.now()) + SESSION_MAX_AGE
	set_cookie(
		b,
		SESSION_COOKIE,
		session_seal(b._session, session_key(b), exp),
		Cookie_Options {
			path = "/",
			http_only = true,
			same_site = .Lax,
			secure = b.ssl != nil, // Secure only over TLS, so dev over HTTP still works
			max_age = SESSION_MAX_AGE,
		},
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

// session_key is App.secret when set, else the insecure default (run() refuses
// to start on the default in release builds). Tolerates a nil _app so a Bifrost
// built in tests still signs.
session_key :: proc(b: ^Bifrost) -> string {
	if b._app != nil && b._app.secret != "" {
		return b._app.secret
	}
	return DEFAULT_SECRET
}

// session_seal wraps values with an absolute expiry, serializes the envelope to
// JSON, base64url-encodes it, and appends a base64url HMAC tag over the whole
// payload: "<payload>.<tag>". `exp` is unix seconds (0 = never expires).
session_seal :: proc(values: map[string]string, key: string, exp: i64) -> string {
	env := Session_Envelope {
		exp  = exp,
		data = values,
	}
	payload, _ := json.marshal(env, {}, context.temp_allocator)
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
	env: Session_Envelope
	if json.unmarshal(payload, &env, allocator = context.temp_allocator) != nil {
		return nil, false
	}
	// Expiry is enforced here, server-side: a well-signed but stale cookie reads
	// as no session. exp == 0 means the token never expires.
	if env.exp != 0 && time.to_unix_seconds(time.now()) > env.exp {
		return nil, false
	}
	return env.data, true
}
