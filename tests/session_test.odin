package tests

// session_test.odin — signed-cookie sessions: round-trip, accumulation, clear,
// and tamper/forgery detection (GH-051). Run with: odin test ./tests

import "core:fmt"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

// sealed_cookie pulls the `gsession=<value>` portion out of a response's queued
// Set-Cookie, i.e. exactly what a browser would echo back on the next request.
sealed_cookie :: proc(b: ^gh.Bifrost) -> string {
	return strings.split(b.cookies[0], ";", context.temp_allocator)[0]
}

// as_request builds a Bifrost whose request carries `name_value` as its cookie.
as_request :: proc(name_value: string) -> gh.Bifrost {
	h, _ := gh.parse_headers(fmt.tprintf("Cookie: %s", name_value), context.temp_allocator)
	return gh.Bifrost{req_headers = h}
}

@(test)
session_round_trip :: proc(t: ^testing.T) {
	out := gh.Bifrost{}
	gh.session_set(&out, "user", "freyja")

	in_req := as_request(sealed_cookie(&out))
	v, ok := gh.session_get(&in_req, "user")
	testing.expect(t, ok, "round-tripped session should read back")
	testing.expect_value(t, v, "freyja")
}

@(test)
session_get_missing :: proc(t: ^testing.T) {
	b := gh.Bifrost{}
	_, ok := gh.session_get(&b, "user")
	testing.expect(t, !ok, "no cookie -> empty session")
}

@(test)
session_sets_accumulate :: proc(t: ^testing.T) {
	// Two sets in one request must both survive, and only one session cookie
	// should be queued (the latest, full one).
	out := gh.Bifrost{}
	gh.session_set(&out, "a", "1")
	gh.session_set(&out, "b", "2")
	testing.expect_value(t, len(out.cookies), 1)

	in_req := as_request(sealed_cookie(&out))
	a, a_ok := gh.session_get(&in_req, "a")
	b, b_ok := gh.session_get(&in_req, "b")
	testing.expect(t, a_ok && b_ok, "both keys present after round-trip")
	testing.expect_value(t, a, "1")
	testing.expect_value(t, b, "2")
}

@(test)
session_clear_expires_cookie :: proc(t: ^testing.T) {
	// Start from a populated session, then clear it.
	out := gh.Bifrost{}
	gh.session_set(&out, "user", "loki")

	in_req := as_request(sealed_cookie(&out))
	gh.session_clear(&in_req)

	_, ok := gh.session_get(&in_req, "user")
	testing.expect(t, !ok, "cleared session is empty")
	// One expiring session cookie queued.
	testing.expect_value(t, len(in_req.cookies), 1)
	testing.expect(t, strings.contains(in_req.cookies[0], "Max-Age=0"), "clear expires the cookie")
}

@(test)
session_detects_tampering :: proc(t: ^testing.T) {
	out := gh.Bifrost{}
	gh.session_set(&out, "role", "user")
	sealed := sealed_cookie(&out) // "gsession=<payload>.<tag>"

	// Flip one byte of the payload (before the '.'), keeping it valid base64url.
	// The HMAC no longer matches, so the session must read as empty — a client
	// can't bump "user" to "admin" by editing the cookie.
	dot := strings.index_byte(sealed, '.')
	bytes := transmute([]u8)strings.clone(sealed, context.temp_allocator)
	flip := dot - 1 // last char of the payload portion
	bytes[flip] = bytes[flip] == 'A' ? 'B' : 'A'
	tampered := string(bytes)

	in_req := as_request(tampered)
	_, ok := gh.session_get(&in_req, "role")
	testing.expect(t, !ok, "tampered cookie must not verify")
}

@(test)
session_cookie_hardened :: proc(t: ^testing.T) {
	// A written session cookie carries HttpOnly + a rolling Max-Age. Secure is
	// omitted over plaintext (b.ssl == nil) so dev over HTTP still works; it is
	// added when the request arrives over TLS.
	b := gh.Bifrost{}
	gh.session_set(&b, "user", "vidar")
	line := b.cookies[0]
	testing.expect(t, strings.contains(line, "HttpOnly"), "session cookie is HttpOnly")
	testing.expect(t, strings.contains(line, "Max-Age=86400"), "session cookie carries rolling Max-Age")
	testing.expect(t, !strings.contains(line, "Secure"), "no Secure flag over plaintext")
}

@(test)
session_expiry_enforced :: proc(t: ^testing.T) {
	// Expiry is signed into the token and checked server-side, so a client can't
	// keep a stale session alive by editing the cookie.
	m := make(map[string]string, context.temp_allocator)
	m["user"] = "odin"

	// exp in the past (unix second 1 = 1970): a valid HMAC must not save it.
	expired := gh.session_seal(m, "k", 1)
	_, ok := gh.session_unseal(expired, "k")
	testing.expect(t, !ok, "expired session must be rejected")

	// exp far in the future: verifies and returns the data.
	future := gh.session_seal(m, "k", 4102444800) // 2100-01-01
	vals, ok2 := gh.session_unseal(future, "k")
	testing.expect(t, ok2, "unexpired session verifies")
	testing.expect_value(t, vals["user"], "odin")
}

@(test)
session_wrong_key_rejected :: proc(t: ^testing.T) {
	// A cookie signed with one secret must not verify under another — so an
	// attacker who doesn't know the key can't forge a session.
	app_a := gh.App {
		secret = "secret-A",
	}
	out := gh.Bifrost {
		_app = &app_a,
	}
	gh.session_set(&out, "user", "thor")

	app_b := gh.App {
		secret = "secret-B",
	}
	in_req := as_request(sealed_cookie(&out))
	in_req._app = &app_b

	_, ok := gh.session_get(&in_req, "user")
	testing.expect(t, !ok, "session signed with a different key is rejected")
}
