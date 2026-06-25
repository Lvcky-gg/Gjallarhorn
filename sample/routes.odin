package sample

import gh "../gjallarhorn"

// Renamed from view.odin: this file holds route wiring, not a view.
// .ward for auth guards

register :: proc(app: ^gh.App) {
	// Literal routes before the :id pattern, else ":id" captures "schema".
	gh.get(app, "/sample/schema", schema_handler)
	gh.get(app, "/sample/:id", get_handler)
}
