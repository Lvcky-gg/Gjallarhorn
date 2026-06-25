package main

import gh "gjallarhorn"
import "sample"

// Mimir is the ORM (gjallarhorn/mimir.odin); it speaks Postgres over a
// from-scratch wire-protocol client (gjallarhorn/postgres.odin).
main :: proc() {
	app := gh.new(gh.Config{
		port    = 8091,
		root    = "/",
		db_type = .Postgres,
		// Set a dbname to go live: run() then connects and auto-migrates every
		// remembered model into real tables. Left empty, migrations just print.
		postgres = gh.Postgres_Config{
			host = "127.0.0.1", port = 5432,
			user = "app", password = "secret", dbname = "gjallarhorn",
		},
	})

	// Middleware is registered with rune, in onion order.
	gh.rune(&app, gh.logger)
	gh.rune(&app, gh.cors)

	// Serve ./public at /docs — a GET that hands back raw files.
	gh.hail(&app, "/docs", "./public")

	// Serve ./templates at /pages, woven by Loom. GET /pages/hello.html renders
	// templates/hello.html through the context loom_context builds per request.
	gh.hail(&app, "/pages", "./templates", loom_context)

	sample.register(&app)
	gh.run(&app)
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
		allocator = context.temp_allocator,
	)
}
