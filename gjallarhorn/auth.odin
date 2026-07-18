package gjallarhorn

// auth.odin — a minimal session-backed login primitive and the Ward that gates
// routes on it (GH-056). login() records the user's id in the signed session;
// require_login is a Ward (router.odin) that admits a request only when a user
// is logged in. For finer authorization (roles, ownership) write your own Ward —
// it's just `proc(b: ^Bifrost) -> bool` — and read current_user / the session.

// AUTH_SESSION_KEY is the reserved session key holding the logged-in user id.
AUTH_SESSION_KEY :: "_uid"

// login marks the session authenticated for user_id (call it after you verify a
// password/OTP/etc.). The id rides in the signed session cookie, so a client
// can't forge or edit it — see session.odin.
login :: proc(b: ^Bifrost, user_id: string) {
	session_set(b, AUTH_SESSION_KEY, user_id)
}

// logout drops the auth key from the session; any other session data survives.
logout :: proc(b: ^Bifrost) {
	session_delete(b, AUTH_SESSION_KEY)
}

// current_user returns the logged-in user id, ok=false when the session is
// anonymous. Handlers behind require_login can rely on ok=true.
current_user :: proc(b: ^Bifrost) -> (string, bool) {
	return session_get(b, AUTH_SESSION_KEY)
}

// require_login is a Ward: it admits the request only when a user is logged in,
// else writes 401 and denies. Attach it to any route needing a session:
//   gh.get(app, "/account", account_handler, gh.require_login)
require_login :: proc(b: ^Bifrost) -> bool {
	if _, ok := current_user(b); ok {
		return true
	}
	text(b, 401, "401 unauthorized: login required")
	return false
}
