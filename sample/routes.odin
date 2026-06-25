package sample

import gh "../gjallarhorn"

// Renamed from view.odin: this file holds route wiring, not a view.
register :: proc(app: ^gh.App) {
	gh.get(app, "/sample/:id", get_handler)
}
