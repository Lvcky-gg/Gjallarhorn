package tests

// pool_test.odin — the connection pool is safe under concurrent handlers
// (GH-024): more worker threads than pool slots, all checking out / returning
// connections. DB-gated; skips if no docker Postgres.
// Run with: odin test ./tests   (needs: docker compose up -d)

import "core:fmt"
import "core:thread"
import "core:testing"
import gh "../gjallarhorn"

// Each worker runs many pooled queries and records how many failed into its own
// slot (no sharing, so no atomics needed).
pool_worker :: proc(app: ^gh.App, failures: ^int) {
	for _ in 0 ..< 25 {
		w := gh.well(app)
		rows, ok := gh.query(w, gh.Statement{sql = "SELECT 1;"})
		if !ok || len(rows.rows) != 1 || len(rows.rows[0]) != 1 || rows.rows[0][0] != "1" {
			failures^ += 1
		}
	}
}

@(test)
pool_safe_under_concurrency :: proc(t: ^testing.T) {
	cfg := gh.Postgres_Config {
		host     = "127.0.0.1",
		port     = 5432,
		user     = "app",
		password = "secret",
		dbname   = "gjallarhorn",
	}

	// Deliberately fewer connections than workers, so checkout must block and
	// hand connections around.
	app := gh.new(gh.Config{db_type = .Postgres, postgres = cfg, pool_size = 3})
	if !gh.connect(&app) {
		fmt.eprintln("pool_test: postgres unavailable; skipping concurrency test")
		return
	}
	defer gh.disconnect(&app)

	WORKERS :: 8
	failures: [WORKERS]int
	threads: [WORKERS]^thread.Thread
	for i in 0 ..< WORKERS {
		threads[i] = thread.create_and_start_with_poly_data2(&app, &failures[i], pool_worker)
	}
	for i in 0 ..< WORKERS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	total := 0
	for f in failures {
		total += f
	}
	testing.expect_value(t, total, 0)
}
