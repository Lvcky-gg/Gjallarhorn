package gjallarhorn

// app.odin — the application object and its construction.
//
// Gjallarhorn is split across several files, all `package gjallarhorn` (Odin
// is one-directory-one-package). Each feature keeps its registration verb next
// to its logic:
//
//   app.odin         App / Config / new
//   router.odin      routes, get/post/put/delete, matching + dispatch
//   middleware.odin  the Rune chain: rune, next, cors, logger
//   static.odin      hail + traversal-safe file serving
//   bifrost.odin     the request/response object and its helpers
//   server.odin      listen / accept / request parsing
//   response.odin    HTTP response writing

DB_Type :: enum {
	Postgres,
	MySQL,
	SQLite,
}

// Postgres_Config: where Mimir's well actually is. Leave dbname empty to stay
// offline — migrations then print their DDL instead of executing. host/port
// default to 127.0.0.1:5432 at connect time. See postgres.odin.
Postgres_Config :: struct {
	host:     string,
	port:     int,
	user:     string,
	password: string,
	dbname:   string,
}

Config :: struct {
	port:     int,
	root:     string,
	db_type:  DB_Type,
	postgres: Postgres_Config,
}

App :: struct {
	port:       int,
	db_type:    DB_Type,     // dialect Mimir speaks; see mimir.odin
	postgres:   Postgres_Config,
	pg:         Pg_Conn,     // live connection; pg.open is false until connect()
	models:     [dynamic]typeid, // shapes Mimir remembers + migrates at startup
	routes:     [dynamic]Route,
	middleware: [dynamic]Middleware,
	statics:    [dynamic]Static_Mount,
}

new :: proc(cfg: Config) -> App {
	return App{port = cfg.port, db_type = cfg.db_type, postgres = cfg.postgres}
}
