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

import "core:fmt"

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
	sslmode:  Ssl_Mode, // TLS policy for the connection; zero value is .Disable (GH-031)
}

// Ssl_Mode selects how the Postgres connection negotiates TLS (GH-031). The zero
// value is .Disable, so existing configs keep their cleartext behaviour. Any mode
// other than .Disable requires a TLS-enabled build: `-define:GJ_TLS=true`.
Ssl_Mode :: enum {
	Disable,     // never attempt TLS; send the startup message in cleartext
	Prefer,      // send SSLRequest; use TLS if offered, fall back to cleartext on 'N'
	Require,     // TLS is mandatory; do not verify the server certificate
	Verify_Full, // TLS is mandatory; verify the certificate chain and hostname
}

// DEFAULT_MAX_BODY caps request bodies when Config.max_body is left zero.
DEFAULT_MAX_BODY :: 1 << 20 // 1 MiB
// DEFAULT_POOL_SIZE is the connection-pool size when Config.pool_size is zero.
DEFAULT_POOL_SIZE :: 4

// DEFAULT_SECRET signs session cookies when Config.secret is left empty. It is a
// fixed, public string — fine for local dev, useless for security. Set a real
// Config.secret in production; new() warns when this fallback is in play.
DEFAULT_SECRET :: "gjallarhorn-insecure-default-key"

Config :: struct {
	host:      string, // bind address, e.g. "0.0.0.0"; empty -> loopback
	port:      int,
	db_type:   DB_Type,
	postgres:  Postgres_Config,
	max_body:  int,    // largest request body accepted; 0 -> DEFAULT_MAX_BODY
	pool_size: int,    // DB connections to pool; 0 -> DEFAULT_POOL_SIZE
	secret:    string, // key signing session cookies; empty -> DEFAULT_SECRET
	// HTTPS (GH-054): set both to serve TLS instead of plaintext HTTP. PEM files.
	// Requires a TLS build (-define:GJ_TLS=true); otherwise startup fails loudly.
	tls_cert:  string, // path to the PEM certificate chain
	tls_key:   string, // path to the PEM private key
}

App :: struct {
	host:       string,      // bind address; empty -> loopback (see server.odin)
	port:       int,
	max_body:   int,         // largest request body accepted, in bytes
	pool_size:  int,         // DB connection-pool size; see postgres.odin
	db_type:    DB_Type,     // dialect Mimir speaks; see mimir.odin
	secret:     string,      // key signing session cookies; see session.odin
	tls_cert:   string,      // PEM cert chain path; with tls_key, serves HTTPS (GH-054)
	tls_key:    string,      // PEM private key path
	tls_ctx:    rawptr,      // OpenSSL SSL_CTX* built at startup; nil for plain HTTP
	postgres:   Postgres_Config,
	pool:       Pg_Pool,     // DB connections; pool.open is false until connect()
	models:     [dynamic]typeid, // shapes Mimir remembers + migrates at startup
	routes:     [dynamic]Route,
	middleware: [dynamic]Middleware,
	statics:    [dynamic]Static_Mount,
	looms:      [dynamic]Loom_Mount, // template dirs served + woven by hail
}

new :: proc(cfg: Config) -> App {
	max_body := cfg.max_body
	if max_body <= 0 {
		max_body = DEFAULT_MAX_BODY
	}
	pool_size := cfg.pool_size
	if pool_size <= 0 {
		pool_size = DEFAULT_POOL_SIZE
	}
	if cfg.secret == "" {
		fmt.eprintln("gjallarhorn: no Config.secret set; signing sessions with the insecure default key")
	}
	return App {
		host      = cfg.host,
		port      = cfg.port,
		max_body  = max_body,
		pool_size = pool_size,
		db_type   = cfg.db_type,
		secret    = cfg.secret,
		tls_cert  = cfg.tls_cert,
		tls_key   = cfg.tls_key,
		postgres  = cfg.postgres,
	}
}
