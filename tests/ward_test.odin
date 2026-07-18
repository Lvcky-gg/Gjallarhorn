package tests

// ward_test.odin — route guards (Wards) and the session-backed login primitive
// (GH-056). A Ward runs after the path matches, before the handler: true admits,
// false blocks. Run with: odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

ward_handler_ok :: proc(b: ^gh.Bifrost) {gh.text(b, 200, "handler ran")}
ward_allow :: proc(b: ^gh.Bifrost) -> bool {return true}
ward_deny_403 :: proc(b: ^gh.Bifrost) -> bool {gh.text(b, 403, "nope"); return false}
ward_deny_silent :: proc(b: ^gh.Bifrost) -> bool {return false}

dispatch :: proc(app: ^gh.App, method: gh.Method, path: string) -> gh.Bifrost {
	b := gh.Bifrost {
		method = method,
		path   = path,
		_app   = app,
	}
	gh.dispatch_route(&b)
	return b
}

@(test)
ward_allows_through_to_handler :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/g", ward_handler_ok, ward_allow)
	b := dispatch(&app, .Get, "/g")
	testing.expect_value(t, b.status, 200) // handler ran
}

@(test)
ward_denial_keeps_its_own_status :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/g", ward_handler_ok, ward_deny_403)
	b := dispatch(&app, .Get, "/g")
	testing.expect_value(t, b.status, 403) // ward's 403, handler never ran
}

@(test)
ward_silent_denial_defaults_to_401 :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/g", ward_handler_ok, ward_deny_silent)
	b := dispatch(&app, .Get, "/g")
	testing.expect_value(t, b.status, 401) // dispatch's fallback
}

@(test)
unwarded_route_runs_normally :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{})
	defer delete(app.routes)
	gh.get(&app, "/g", ward_handler_ok) // no ward
	b := dispatch(&app, .Get, "/g")
	testing.expect_value(t, b.status, 200)
}

@(test)
require_login_denies_anonymous :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Get}
	ok := gh.require_login(&b)
	testing.expect(t, !ok, "anonymous request is denied")
	testing.expect_value(t, b.status, 401)
}

@(test)
require_login_admits_logged_in :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Get}
	gh.login(&b, "user-42")
	ok := gh.require_login(&b)
	testing.expect(t, ok, "a logged-in request is admitted")

	uid, has := gh.current_user(&b)
	testing.expect(t, has, "current_user returns the id")
	testing.expect_value(t, uid, "user-42")
}

@(test)
logout_clears_the_user :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Get}
	gh.login(&b, "u")
	gh.logout(&b)
	_, has := gh.current_user(&b)
	testing.expect(t, !has, "logout clears the session user")
}
