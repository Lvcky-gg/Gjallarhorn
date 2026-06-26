package tests

// error_test.odin — structured driver errors with SQLSTATE (GH-032). The parse
// test is pure; the surfacing test triggers a real server error and inspects
// the code. DB test skips if no docker Postgres.
// Run with: odin test ./tests   (DB test needs: docker compose up -d)

import "core:fmt"
import "core:net"
import "core:testing"
import gh "../gjallarhorn"

@(test)
parse_pg_error_fields :: proc(t: ^testing.T) {
	// An ErrorResponse payload: [field-byte][cstring]... then a 0 terminator.
	payload: [dynamic]u8
	defer delete(payload)
	append(&payload, 'S');  append(&payload, ..transmute([]u8)string("ERROR"));    append(&payload, 0)
	append(&payload, 'C');  append(&payload, ..transmute([]u8)string("23505"));    append(&payload, 0)
	append(&payload, 'M');  append(&payload, ..transmute([]u8)string("duplicate")); append(&payload, 0)
	append(&payload, 0) // end of fields

	e := gh.parse_pg_error(payload[:], context.temp_allocator)
	testing.expect_value(t, e.severity, "ERROR")
	testing.expect_value(t, e.code, "23505")
	testing.expect_value(t, e.message, "duplicate")
}

@(test)
query_error_surfaces_sqlstate :: proc(t: ^testing.T) {
	conn: gh.Pg_Conn
	cfg := gh.Postgres_Config {
		host = "127.0.0.1", port = 5432, user = "app", password = "secret", dbname = "gjallarhorn",
	}
	if !gh.pg_open(&conn, cfg) {
		fmt.eprintln("error_test: postgres unavailable; skipping SQLSTATE test")
		return
	}
	defer net.close(conn.sock)

	// Selecting a missing table yields SQLSTATE 42P01 (undefined_table).
	rows, ok := gh.pg_query(&conn, "SELECT * FROM nope_does_not_exist;", nil)
	testing.expect(t, !ok, "the query should fail")
	testing.expect(t, gh.failed(rows), "failed() should report the server error")
	testing.expect_value(t, rows.err.code, "42P01")
	testing.expect_value(t, rows.err.severity, "ERROR")
	testing.expect(t, rows.err.message != "", "a message should be present")

	// A clean query carries no error.
	good, gok := gh.pg_query(&conn, "SELECT 1;", nil)
	testing.expect(t, gok)
	testing.expect(t, !gh.failed(good), "a successful query has no error")
}
