package sample

import gh "../gjallarhorn"

// Wards (auth guards) attach to a route as the optional 4th arg — the handler
// runs only if the ward returns true, e.g. a login-gated route:
//   gh.get(app, "/account", account_handler, gh.require_login)
// See the /login + /account demo wired in main.odin.

register :: proc(app: ^gh.App) {
	// Hand Mimir the model; its table is auto-migrated at run(). No SQL here.
	gh.remember(app, Sample)

	// Literal routes before the :id pattern, else ":id" captures "schema".
	gh.get(app, "/sample/schema", schema_handler)
	gh.get(app, "/sample/:id", get_handler)

	// CRUD against Postgres via Mimir. Create/update take their payload from a
	// JSON body; only the id rides in the path. Method is matched before path,
	// so these never clash with the GETs.
	gh.post(app, "/sample", create_handler)            // create from JSON body
	gh.put(app, "/sample/:id", update_handler)         // update name by id, body
	gh.delete(app, "/sample/:id", delete_handler)      // delete by id

	// Describe the routes for the OpenAPI docs page (Config.docs). Optional — a
	// route without a describe still lists, just without a schema. The request /
	// response types are reflected into JSON Schema + an example body you can edit
	// and fire from the "Try it" panel at /api-docs.
	gh.describe(app, .Get, "/sample/:id", {summary = "Fetch one sample by id", response = Sample})
	gh.describe(app, .Post, "/sample", {summary = "Create a sample", request = Sample, response = Sample})
	gh.describe(app, .Put, "/sample/:id", {summary = "Update a sample's name", request = Sample, response = Sample})
	gh.describe(app, .Delete, "/sample/:id", {summary = "Delete a sample by id"})
}
