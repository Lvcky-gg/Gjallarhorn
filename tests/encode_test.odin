package tests

// encode_test.odin — typed bind-argument encoding (GH-021). The table test is
// pure; the round-trip test sends bytea + timestamp through the docker Postgres
// and reads them back, and skips if no DB is reachable.
// Run with: odin test ./tests   (DB test needs: docker compose up -d)

import "core:fmt"
import "core:net"
import "core:time"
import "core:testing"
import gh "../gjallarhorn"

Unsupported :: struct {
	x: int,
}

@(test)
encode_arg_table :: proc(t: ^testing.T) {
	expect_enc :: proc(t: ^testing.T, a: any, want: string, loc := #caller_location) {
		got, ok := gh.encode_arg(a, context.temp_allocator)
		testing.expect(t, ok, "type should be supported")
		testing.expect_value(t, got, want)
	}

	expect_enc(t, 42, "42")
	expect_enc(t, i64(-7), "-7")
	expect_enc(t, u32(9), "9")
	expect_enc(t, 3.5, "3.5")
	expect_enc(t, true, "t")
	expect_enc(t, false, "f")
	expect_enc(t, "loki", "loki")
	expect_enc(t, []u8{0xDE, 0xAD, 0xBE, 0xEF}, "\\xdeadbeef")

	when_, _ := time.components_to_time(2026, 6, 26, 9, 8, 7)
	expect_enc(t, when_, "2026-06-26 09:08:07")

	// An unsupported type must fail loudly rather than silently stringify.
	_, ok := gh.encode_arg(Unsupported{x = 1}, context.temp_allocator)
	testing.expect(t, !ok, "unknown types are rejected, not %v-stringified")
}

Stored :: struct {
	id:   int    `db:"id,pk,auto"`,
	blob: string `db:"blob"`, // bytea read back as text (hex) by scan
	at:   string `db:"at"`,   // timestamp read back as text
}

@(test)
encode_roundtrip_against_postgres :: proc(t: ^testing.T) {
	conn: gh.Pg_Conn
	cfg := gh.Postgres_Config {
		host     = "127.0.0.1",
		port     = 5432,
		user     = "app",
		password = "secret",
		dbname   = "gjallarhorn",
	}
	if !gh.pg_open(&conn, cfg) {
		fmt.eprintln("encode_test: postgres unavailable; skipping DB round-trip")
		return
	}
	defer net.close(conn.sock)

	gh.pg_query(&conn, "DROP TABLE IF EXISTS encode_probe;", nil)
	gh.pg_query(
		&conn,
		"CREATE TABLE encode_probe (id BIGINT, blob BYTEA, at TIMESTAMP);",
		nil,
	)

	when_, _ := time.components_to_time(2026, 6, 26, 9, 8, 7)
	_, ins_ok := gh.pg_query(
		&conn,
		"INSERT INTO encode_probe (id, blob, at) VALUES ($1, $2, $3);",
		[]any{1, []u8{0xDE, 0xAD, 0xBE, 0xEF}, when_},
	)
	testing.expect(t, ins_ok, "typed bytea + timestamp params should be accepted")

	// Read them back rendered as text so we can assert exact wire values.
	rows, ok := gh.pg_query(
		&conn,
		"SELECT id, encode(blob, 'hex') AS blob, to_char(at, 'YYYY-MM-DD HH24:MI:SS') AS at FROM encode_probe;",
		nil,
	)
	testing.expect(t, ok)

	row, found := gh.scan_one(rows, Stored)
	testing.expect(t, found)
	testing.expect_value(t, row.blob, "deadbeef")
	testing.expect_value(t, row.at, "2026-06-26 09:08:07")

	gh.pg_query(&conn, "DROP TABLE IF EXISTS encode_probe;", nil)
}
