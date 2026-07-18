package main

import "core:fmt"
import gh "gjallarhorn"
import "sample"

// Mimir is the ORM (gjallarhorn/mimir.odin); it speaks Postgres over a
// from-scratch wire-protocol client (gjallarhorn/postgres.odin).
main :: proc() {
	app := gh.new(gh.Config{
		port    = 8091,
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
	gh.rune(&app, gh.logger)
	gh.rune(&app, gh.cors)
	gh.rune(&app, gh.csrf)

	// Serve ./docs at /docs — a GET that hands back raw files.
	gh.hail(&app, "/docs", "./docs")

	// Serve ./templates at /pages, woven by Loom. GET /pages/hello.html renders
	// templates/hello.html through the context loom_context builds per request.
	gh.hail(&app, "/pages", "./templates", loom_context)

	// CSRF demo: /pages/form.html renders a form carrying the session's token;
	// posting it here passes the csrf rune, which has already verified the token.
	gh.post(&app, "/submit", submit_handler)

	sample.register(&app)
	gh.run(&app)
}

// submit_handler runs only after the csrf rune verifies the token, so reaching it
// means the request carried a valid CSRF token for this session.
submit_handler :: proc(b: ^gh.Bifrost) {
	name := gh.form(b)["name"]
	gh.text(b, 200, fmt.tprintf("CSRF ok — received name=%q", name))
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
