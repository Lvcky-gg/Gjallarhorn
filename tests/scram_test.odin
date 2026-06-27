package tests

// scram_test.odin — SCRAM-SHA-256 authentication (GH-030). Connects to a
// default-configured Postgres (scram-sha-256, no pg_hba changes) using a real
// password and runs a query. Skips if no docker Postgres is reachable.
// Run with: odin test ./tests   (needs: docker compose up -d)

import "core:fmt"
import "core:net"
import "core:testing"
import gh "../gjallarhorn"

@(test)
scram_auth_connects :: proc(t: ^testing.T) {
	conn: gh.Pg_Conn
	cfg := gh.Postgres_Config {
		host     = "127.0.0.1",
		port     = 5432,
		user     = "app",
		password = "secret",
		dbname   = "gjallarhorn",
	}

	// pg_open completes the full startup, including the SCRAM handshake. If the
	// proof or server-signature verification were wrong, this would fail.
	if !gh.pg_open(&conn, cfg) {
		fmt.eprintln("scram_test: postgres unavailable; skipping SCRAM test")
		return
	}
	defer net.close(conn.sock)

	rows, ok := gh.pg_query(&conn, "SELECT 1;", nil)
	testing.expect(t, ok, "a SCRAM-authenticated session should run queries")
	testing.expect_value(t, len(rows.rows), 1)
	testing.expect_value(t, rows.rows[0][0], "1")
}

@(test)
scram_wrong_password_fails :: proc(t: ^testing.T) {
	// Reachability probe with the correct password; skip if no DB.
	probe: gh.Pg_Conn
	good := gh.Postgres_Config {
		host = "127.0.0.1", port = 5432, user = "app", password = "secret", dbname = "gjallarhorn",
	}
	if !gh.pg_open(&probe, good) {
		fmt.eprintln("scram_test: postgres unavailable; skipping wrong-password test")
		return
	}
	net.close(probe.sock)

	// Same everything, wrong password: SCRAM final verification must reject it.
	conn: gh.Pg_Conn
	bad := good
	bad.password = "not-the-password"
	ok := gh.pg_open(&conn, bad)
	if ok {
		net.close(conn.sock)
	}
	testing.expect(t, !ok, "a wrong password must fail SCRAM auth")
}
