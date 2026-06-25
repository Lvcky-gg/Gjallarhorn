package sample

import gh "../gjallarhorn"

// Renamed from view.odin: this file holds route wiring, not a view.
// .ward for auth guards

register :: proc(app: ^gh.App) {
	gh.get(app, "/sample/:id", get_handler)
}
