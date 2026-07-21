package main

import "core:fmt"
import "core:os"
import "core:strconv"
import gh "gjallarhorn"
import "sample"

// Mimir is the ORM (gjallarhorn/mimir.odin); it speaks Postgres over a
// from-scratch wire-protocol client (gjallarhorn/postgres.odin).
main :: proc() {
	// GJ_WORKERS overrides the connection worker-pool size — handy for the
	// benchmark harness (bench/) to sweep it; 0/unset uses the default.
	workers := 0
	if s, ok := os.lookup_env("GJ_WORKERS", context.temp_allocator); ok {
		workers, _ = strconv.parse_int(s)
	}

	app := gh.new(gh.Config{
		port    = 8091,
		workers = workers,
		// host left empty -> bind to loopback. Set e.g. "0.0.0.0" to expose.
		db_type = .Postgres,
		// Set a dbname to go live: run() then connects and auto-migrates every
		// remembered model into real tables. Left empty, migrations just print.
		postgres = gh.Postgres_Config{
			host = "127.0.0.1", port = 5432,
			user = "app", password = "secret", dbname = "gjallarhorn",
		},
		secret = "asdwASDWdadndaoiwdjkasdwe",
	})

	// Middleware is registered with rune, in onion order. csrf guards unsafe
	// methods: GET /pages/form.html seeds a token, POST /submit requires it.
	// Observability: metrics outermost (times the whole chain and serves
	// /metrics), then request_id (before logger, so the id reaches the log line
	// and the X-Request-Id response header).
	gh.rune(&app, gh.metrics)
	gh.rune(&app, gh.request_id)
	gh.rune(&app, gh.logger)
	gh.rune(&app, gh.cors)
	// Per-client token bucket: bursts pass, sustained excess gets 429 +
	// Retry-After. Tuned low here so the demo is easy to trip; the defaults
	// (10/sec, burst 20) suit ordinary browsing.
	gh.rate_limit_rps = 5
	gh.rate_limit_burst = 10
	gh.rune(&app, gh.rate_limit)
	gh.rune(&app, gh.csrf)

	// Branded error page: replace the plain-text 404 with our own HTML. on_error
	// covers the errors the framework generates (404/500/403/401); an app-written
	// error keeps its own message.
	gh.on_error(&app, 404, not_found_page)

	// Hash the demo account's password once at startup (context.allocator, not
	// temp — it has to outlive the request that checks it). A real app stores
	// this string in the users table at signup instead.
	if h, ok := gh.hash_password(DEMO_PASSWORD, context.allocator); ok {
		demo_password_hash = h
	}

	// Serve ./docs at /docs — a GET that hands back raw files.
	gh.hail(&app, "/docs", "./docs")

	// Serve ./templates at /pages, woven by Loom. GET /pages/hello.html renders
	// templates/hello.html through the context loom_context builds per request.
	gh.hail(&app, "/pages", "./templates", loom_context)

	// CSRF demo: /pages/form.html renders a form carrying the session's token;
	// posting it here passes the csrf rune, which has already verified the token.
	gh.post(&app, "/submit", submit_handler)

	// Ward demo (full browser flow): GET /pages/login.html is the form (its hidden
	// field carries the CSRF token from loom_context). POST /login logs the user in
	// and redirects to /account, which the require_login ward guards. POST /logout
	// clears the session. All three POSTs pass through the csrf rune.
	gh.post(&app, "/login", login_handler)
	gh.post(&app, "/logout", logout_handler)
	gh.get(&app, "/account", account_handler, gh.require_login)

	// Multipart demo: POST a form with a file part (multipart/form-data). The csrf
	// rune still guards it — the token rides as a normal field, which form() now
	// surfaces from a multipart body just like a urlencoded one.
	gh.post(&app, "/upload", upload_handler)

	sample.register(&app)
	gh.run(&app)
}

// submit_handler runs only after the csrf rune verifies the token, so reaching it
// means the request carried a valid CSRF token for this session.
submit_handler :: proc(b: ^gh.Bifrost) {
	name := gh.form(b)["name"]
	gh.text(b, 200, fmt.tprintf("CSRF ok — received name=%q", name))
}

// login_handler stands in for real credential checking — the demo logs in the
// submitted username, recording it in the signed session so the require_login
// ward admits later requests, then redirects to the guarded page.
// The demo's "user store": one account whose password is hashed at startup (see
// main), so nothing here is a plaintext or hardcoded credential. A real app
// would look the row up in Mímir and compare against the stored hash the same way.
DEMO_USER :: "ratatoskr"
DEMO_PASSWORD :: "gjallarhorn"
demo_password_hash: string

// login_handler verifies the submitted credentials with Argon2id before opening
// a session. verify_password is constant time, and both the unknown-user and
// wrong-password paths answer identically so neither leaks which one it was.
login_handler :: proc(b: ^gh.Bifrost) {
	fields := gh.form(b)
	username, password := fields["username"], fields["password"]

	if username != DEMO_USER || !gh.verify_password(password, demo_password_hash) {
		gh.text(b, 401, "401 invalid username or password")
		return
	}
	gh.login(b, username)
	gh.redirect(b, "/account")
}

// logout_handler clears the session user and returns to the login form.
logout_handler :: proc(b: ^gh.Bifrost) {
	gh.logout(b)
	gh.redirect(b, "/pages/login.html")
}

// account_handler is reached only past the require_login ward, so current_user is
// always present. It renders the account page with a CSRF-protected logout form.
account_handler :: proc(b: ^gh.Bifrost) {
	uid, _ := gh.current_user(b)
	gh.render(
		b,
		"./templates/account.html",
		gh.warp(
			{"user", uid},
			{"csrf_token", gh.csrf_token(b)},
			allocator = context.temp_allocator,
		),
	)
}

// upload_handler receives a multipart/form-data POST: a text field plus an
// uploaded file. It echoes what it decoded, proving files() reads the file bytes
// exactly and form() still sees the text fields (including the CSRF token).
upload_handler :: proc(b: ^gh.Bifrost) {
	title := gh.form(b)["title"]
	f, ok := gh.upload(b, "file")
	if !ok {
		gh.text(b, 400, "expected a `file` part")
		return
	}
	gh.text(
		b,
		200,
		fmt.tprintf(
			"uploaded: title=%q filename=%q type=%q bytes=%d",
			title,
			f.filename,
			f.content_type,
			len(f.data),
		),
	)
}

// not_found_page renders a branded 404 instead of the framework's plain text.
// Registered with gh.on_error(&app, 404, …).
not_found_page :: proc(b: ^gh.Bifrost) {
	gh.html(
		b,
		404,
		"<!doctype html><title>404 — Gjallarhorn</title>" +
		"<h1>ᚷ Lost in Niflheim</h1><p>No route answers here. " +
		"<a href=\"/docs\">Back to the docs.</a></p>",
	)
}

// loom_context threads the context for templates under /pages. Built fresh per
// request in temp memory; `warp` nests (objects are warps, lists are []Value).
// Output is HTML-escaped by default — the title below proves it.
loom_context :: proc(b: ^gh.Bifrost) -> gh.Warp {
	return gh.warp(
		{"title", "Gjallarhorn <Loom>"},
		{"user", gh.warp({"name", "Heimdallr"}, {"admin", true}, allocator = context.temp_allocator)},
		{"items", gh.list("urd", "verdandi", "skuld", allocator = context.temp_allocator)},
		{"path", b.path},
		// The session's CSRF token, for form.html's hidden field. csrf_token mints
		// it if the csrf rune hasn't already seeded one this request.
		{"csrf_token", gh.csrf_token(b)},
		allocator = context.temp_allocator,
	)
}
