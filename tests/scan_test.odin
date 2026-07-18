package tests

// scan_test.odin — hydrating Pg_Rows into typed structs (GH-020). The first
// test is pure (synthetic rows, always runs); the second exercises a real
// round-trip against the docker Postgres and skips if none is reachable.
// Run with: odin test ./tests   (DB test needs: docker compose up -d)

import "core:fmt"
import "core:net"
import "core:testing"
import gh "../gjallarhorn"

Probe :: struct {
	id:    int    `db:"id,pk,auto"`,
	ratio: f64    `db:"ratio"`,
	flag:  bool   `db:"flag"`,
	label: string `db:"label"`,
	maybe: string `db:"maybe"`,
}

@(test)
scan_converts_each_type :: proc(t: ^testing.T) {
	rows := gh.Pg_Rows {
		columns = []string{"id", "ratio", "flag", "label", "maybe"},
		rows = [][]string{
			{"42", "3.5", "t", "heimdallr", "present"},
			{"7", "0.25", "f", "loki", ""}, // empty cell == NULL -> zero value
		},
	}

	out := gh.scan(rows, Probe, context.temp_allocator)
	testing.expect_value(t, len(out), 2)

	testing.expect_value(t, out[0].id, 42)
	testing.expect_value(t, out[0].ratio, 3.5)
	testing.expect_value(t, out[0].flag, true)
	testing.expect_value(t, out[0].label, "heimdallr")
	testing.expect_value(t, out[0].maybe, "present")

	testing.expect_value(t, out[1].id, 7)
	testing.expect_value(t, out[1].ratio, 0.25)
	testing.expect_value(t, out[1].flag, false)
	testing.expect_value(t, out[1].label, "loki")
	testing.expect_value(t, out[1].maybe, "") // NULL -> zero value
}

// NullProbe uses Maybe(T) fields — the nullable shape that can hold SQL NULL
// distinctly from a zero/empty value.
NullProbe :: struct {
	name:  Maybe(string) `db:"name"`,
	count: Maybe(int)    `db:"count"`,
}

@(test)
data_row_null_vs_empty :: proc(t: ^testing.T) {
	// A DataRow with three fields: SQL NULL (length -1), empty (length 0), "hi".
	// The wire layer must keep NULL and empty apart (GH-024).
	payload := []u8 {
		0x00, 0x03, // field count = 3
		0xFF, 0xFF, 0xFF, 0xFF, // field 0: length -1 => SQL NULL
		0x00, 0x00, 0x00, 0x00, // field 1: length 0  => empty value
		0x00, 0x00, 0x00, 0x02, 0x68, 0x69, // field 2: "hi"
	}
	row, nulls := gh.parse_data_row(payload, context.temp_allocator)
	testing.expect_value(t, len(row), 3)
	testing.expect(t, nulls[0], "field 0 is SQL NULL")
	testing.expect(t, !nulls[1], "field 1 is empty, not NULL")
	testing.expect(t, !nulls[2], "field 2 has a value")
	testing.expect_value(t, row[0], "") // NULL placeholder
	testing.expect_value(t, row[1], "") // real empty
	testing.expect_value(t, row[2], "hi")
}

@(test)
scan_distinguishes_null_from_empty :: proc(t: ^testing.T) {
	// The payoff: a Maybe(T) field reads SQL NULL as None, and a real empty/zero
	// value as Some — so the two are no longer conflated on hydration.
	rows := gh.Pg_Rows {
		columns = []string{"name", "count"},
		rows = [][]string{
			{"", ""},  // row 0: both SQL NULL
			{"", "0"}, // row 1: name = "" (real empty), count = 0
		},
		nulls = [][]bool{{true, true}, {false, false}},
	}
	out := gh.scan(rows, NullProbe, context.temp_allocator)
	testing.expect_value(t, len(out), 2)

	_, name_some0 := out[0].name.?
	_, count_some0 := out[0].count.?
	testing.expect(t, !name_some0, "NULL name -> None")
	testing.expect(t, !count_some0, "NULL count -> None")

	name1, name_some1 := out[1].name.?
	count1, count_some1 := out[1].count.?
	testing.expect(t, name_some1, "empty-string name -> Some, not None")
	testing.expect_value(t, name1, "")
	testing.expect(t, count_some1, "zero count -> Some, not None")
	testing.expect_value(t, count1, 0)
}

@(test)
scan_one_empty_set :: proc(t: ^testing.T) {
	empty := gh.Pg_Rows {
		columns = []string{"id"},
		rows    = [][]string{},
	}
	_, found := gh.scan_one(empty, Probe)
	testing.expect(t, !found, "an empty result set yields ok=false")
}

@(test)
scan_roundtrip_against_postgres :: proc(t: ^testing.T) {
	conn: gh.Pg_Conn
	cfg := gh.Postgres_Config {
		host     = "127.0.0.1",
		port     = 5432,
		user     = "app",
		password = "secret",
		dbname   = "gjallarhorn",
	}
	if !gh.pg_open(&conn, cfg) {
		fmt.eprintln("scan_test: postgres unavailable (docker compose up -d); skipping DB scan test")
		return
	}
	defer net.close(conn.sock)

	gh.pg_query(&conn, "DROP TABLE IF EXISTS scan_probe;", nil)
	gh.pg_query(
		&conn,
		"CREATE TABLE scan_probe (id BIGINT, ratio DOUBLE PRECISION, flag BOOLEAN, label TEXT, maybe TEXT);",
		nil,
	)
	gh.pg_query(
		&conn,
		"INSERT INTO scan_probe (id, ratio, flag, label, maybe) VALUES ($1,$2,$3,$4,$5);",
		[]any{42, 3.5, true, "heimdallr", nil},
	)

	rows, ok := gh.pg_query(&conn, "SELECT id, ratio, flag, label, maybe FROM scan_probe;", nil)
	testing.expect(t, ok, "select should succeed")

	probe, found := gh.scan_one(rows, Probe)
	testing.expect(t, found, "one row expected")
	testing.expect_value(t, probe.id, 42)
	testing.expect_value(t, probe.ratio, 3.5)
	testing.expect_value(t, probe.flag, true)
	testing.expect_value(t, probe.label, "heimdallr")
	testing.expect_value(t, probe.maybe, "") // SQL NULL -> zero value

	gh.pg_query(&conn, "DROP TABLE IF EXISTS scan_probe;", nil)
}
