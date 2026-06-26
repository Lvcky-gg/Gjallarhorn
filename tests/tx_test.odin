package tests

// tx_test.odin — transaction atomicity over the connection pool (GH-022 +
// GH-024): a failed second statement rolls back the first, on the connection tx
// pins. DB-gated; skips if no docker Postgres is reachable.
// Run with: odin test ./tests   (needs: docker compose up -d)

import "core:fmt"
import "core:net"
import "core:testing"
import gh "../gjallarhorn"

// Body that fails on its second statement (duplicate primary key). It runs on
// the connection tx pinned into the Well (w.conn).
tx_body_fails :: proc(w: gh.Well) -> bool {
	if _, ok := gh.pg_query(w.conn, "INSERT INTO tx_probe (id) VALUES (1);", nil); !ok {
		return false
	}
	// Same id again -> PK violation -> ok=false -> roll back.
	if _, ok := gh.pg_query(w.conn, "INSERT INTO tx_probe (id) VALUES (1);", nil); !ok {
		return false
	}
	return true
}

tx_body_ok :: proc(w: gh.Well) -> bool {
	_, ok := gh.pg_query(w.conn, "INSERT INTO tx_probe (id) VALUES (2);", nil)
	return ok
}

count_rows :: proc(conn: ^gh.Pg_Conn) -> int {
	rows, _ := gh.pg_query(conn, "SELECT id FROM tx_probe;", nil)
	return len(rows.rows)
}

@(test)
tx_rolls_back_failed_batch :: proc(t: ^testing.T) {
	cfg := gh.Postgres_Config {
		host     = "127.0.0.1",
		port     = 5432,
		user     = "app",
		password = "secret",
		dbname   = "gjallarhorn",
	}

	app := gh.new(gh.Config{db_type = .Postgres, postgres = cfg, pool_size = 2})
	if !gh.connect(&app) {
		fmt.eprintln("tx_test: postgres unavailable; skipping transaction test")
		return
	}
	defer gh.disconnect(&app)
	w := gh.well(&app)

	// A standalone connection for DDL setup and out-of-transaction asserts.
	probe: gh.Pg_Conn
	gh.pg_open(&probe, cfg)
	defer net.close(probe.sock)

	gh.pg_query(&probe, "DROP TABLE IF EXISTS tx_probe;", nil)
	gh.pg_query(&probe, "CREATE TABLE tx_probe (id INT PRIMARY KEY);", nil)

	// Failing batch: tx reports false and leaves the table empty (row 1 undone).
	ok := gh.tx(w, tx_body_fails)
	testing.expect(t, !ok, "a failed statement should make tx report failure")
	testing.expect_value(t, count_rows(&probe), 0)

	// Happy path: a clean body commits and the row persists.
	ok2 := gh.tx(w, tx_body_ok)
	testing.expect(t, ok2, "a clean body should commit")
	testing.expect_value(t, count_rows(&probe), 1)

	// Explicit verbs on a pinned Well: begin, insert, rollback discards it.
	pw, pinned := gh.pin(w)
	testing.expect(t, pinned, "pin should check out a connection")
	testing.expect(t, gh.begin(pw))
	gh.pg_query(pw.conn, "INSERT INTO tx_probe (id) VALUES (3);", nil)
	testing.expect(t, gh.rollback(pw))
	gh.unpin(pw)
	testing.expect_value(t, count_rows(&probe), 1) // still just row 2

	gh.pg_query(&probe, "DROP TABLE IF EXISTS tx_probe;", nil)
}
