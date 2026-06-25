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

	// Serve ./public at /static — a GET that hands back files.
	gh.hail(&app, "/docs", "./public")

	// Loom: render an HTML template (templates/hello.html) through a context.
	gh.get(&app, "/loom", loom_demo)

	sample.register(&app)
	gh.run(&app)
}

// loom_demo weaves templates/hello.html. `warp` threads the context; nested
// objects are just nested `warp`s, lists are []gh.Value. Output is
// HTML-escaped by default — the title below proves it.
loom_demo :: proc(b: ^gh.Bifrost) {
	gh.render(b, "templates/hello.html", gh.warp(
		{"title", "Gjallarhorn <Loom>"},
		{"user", gh.warp({"name", "Heimdallr"}, {"admin", true})},
		{"items", []gh.Value{"urd", "verdandi", "skuld"}},
	))
}
