package sample

import gh "../gjallarhorn"

// .ward for auth guards

register :: proc(app: ^gh.App) {
	// Hand Mimir the model; its table is auto-migrated at run(). No SQL here.
	gh.remember(app, Sample)

	// Literal routes before the :id pattern, else ":id" captures "schema".
	gh.get(app, "/sample/schema", schema_handler)
	gh.get(app, "/sample/:id", get_handler)

	// CRUD against Postgres via Mimir. Data rides in the path (no body parser
	// yet). Method is matched before path, so these never clash with the GETs.
	gh.post(app, "/sample/:name", create_handler)      // create
	gh.put(app, "/sample/:id/:name", update_handler)   // update name by id
	gh.delete(app, "/sample/:id", delete_handler)      // delete by id
}
