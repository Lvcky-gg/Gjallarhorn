package main

import gh "gjallarhorn"
import "sample"

//name the ORM Mimir
main :: proc() {
	app := gh.new(gh.Config{port = 8091, root = "/", db_type = .Postgres})

	// Middleware is registered with rune, in onion order.
	gh.rune(&app, gh.logger)
	gh.rune(&app, gh.cors)

	// Serve ./public at /static — a GET that hands back files.
	gh.hail(&app, "/static", "./public")

	sample.register(&app)
	gh.run(&app)
}
