package gjallarhorn

// csrf.odin — CSRF protection as a Rune (GH-055). Uses the synchronizer-token
// pattern: a per-session secret token that a cross-site attacker can't read (it
// rides in the signed session cookie, and same-origin policy hides the response
// body / header from other origins). State-changing requests must echo it back.
//
// The token is stored in the session (session.odin), so it inherits the session
// cookie's HMAC integrity and the same key discipline (run() refuses to start on
// the default secret). Safe methods (GET/HEAD/OPTIONS) pass through and seed a
// token; unsafe methods (POST/PUT/PATCH/DELETE) must present a matching token in
// the `X-CSRF-Token` header or a `csrf_token` form field, or they get a 403.
//
// Register it after session config is in place; it runs per request like any Rune:
//   gh.rune(&app, gh.csrf)
//
// Handlers/templates read the token to embed it, e.g.:
//   token := gh.csrf_token(b)                      // <input type=hidden name=csrf_token ...>
//   // or hand it to fetch() as the X-CSRF-Token header.

import "core:crypto"
import "core:encoding/base64"

// CSRF_SESSION_KEY is the reserved session key holding the token.
CSRF_SESSION_KEY :: "_csrf"
// CSRF_HEADER is the request header carrying the token (lookup is case-insensitive).
CSRF_HEADER :: "X-CSRF-Token"
// CSRF_FIELD is the form field carrying the token on a urlencoded POST.
CSRF_FIELD :: "csrf_token"
// CSRF_TOKEN_BYTES is the raw entropy per token; base64url-encodes to ~43 chars.
CSRF_TOKEN_BYTES :: 32

// csrf is the middleware. Safe methods seed a token and pass through; unsafe
// methods must present one that matches the session's, else 403.
csrf :: proc(b: ^Bifrost, next: Next) {
	token, has := session_get(b, CSRF_SESSION_KEY)

	if csrf_safe_method(b.method) {
		// Seed a token so this session's forms / scripts have one to send back.
		if !has || token == "" {
			session_set(b, CSRF_SESSION_KEY, csrf_new_token())
		}
		next(b)
		return
	}

	// State-changing request: require the session token and a matching submission.
	presented := csrf_presented_token(b)
	if !has || token == "" || !csrf_token_equal(presented, token) {
		text(b, 403, "403 forbidden: missing or invalid CSRF token")
		return // do not call next
	}
	next(b)
}

// csrf_token returns the current session's CSRF token, minting one if the session
// doesn't have it yet, so handlers and templates can embed it.
csrf_token :: proc(b: ^Bifrost) -> string {
	token, has := session_get(b, CSRF_SESSION_KEY)
	if !has || token == "" {
		token = csrf_new_token()
		session_set(b, CSRF_SESSION_KEY, token)
	}
	return token
}

// csrf_safe_method reports the methods that don't change state and so carry no
// CSRF requirement (RFC 7231 §4.2.1 safe methods).
csrf_safe_method :: proc(m: Method) -> bool {
	#partial switch m {
	case .Get, .Head, .Options:
		return true
	}
	return false
}

// csrf_new_token mints a fresh base64url token from CSPRNG entropy.
csrf_new_token :: proc() -> string {
	raw: [CSRF_TOKEN_BYTES]u8
	crypto.rand_bytes(raw[:])
	return base64.encode(raw[:], base64.ENC_URL_TABLE, context.temp_allocator)
}

// csrf_presented_token pulls the submitted token: the X-CSRF-Token header first
// (the path JSON/fetch clients use), then a `csrf_token` urlencoded form field.
csrf_presented_token :: proc(b: ^Bifrost) -> string {
	if v, ok := header(b, CSRF_HEADER); ok && v != "" {
		return v
	}
	if v, ok := form(b)[CSRF_FIELD]; ok && v != "" {
		return v
	}
	return ""
}

// csrf_token_equal compares two tokens in constant time. An empty or
// length-mismatched submission is never equal.
csrf_token_equal :: proc(a, b: string) -> bool {
	if len(a) == 0 || len(a) != len(b) {
		return false
	}
	return crypto.compare_constant_time(transmute([]byte)a, transmute([]byte)b) == 1
}
