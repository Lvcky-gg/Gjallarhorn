package sample

import gh "../gjallarhorn"

// (value, ok) returns, idiomatic Odin error handling.
get_handler :: proc(b: ^gh.Bifrost) {
	id, ok := gh.param_int(b, "id")
	if !ok {
		gh.text(b, 400, "id must be an integer")
		return
	}
	gh.json(b, 200, Sample{id = id, name = "thing"})
}
