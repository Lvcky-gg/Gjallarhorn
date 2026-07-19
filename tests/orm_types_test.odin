package tests

// orm_types_test.odin — extended Mímir column types: time.Time (timestamptz),
// []u8 (bytea), Uuid, and Json (jsonb), plus their Maybe(T) nullable forms. The
// pure tests cover DDL mapping, the text parsers, and bind encoding; the DB test
// round-trips all four through the docker Postgres and skips if none is up.
// Run with: odin test ./tests   (DB test needs: docker compose up -d)

import "core:encoding/uuid"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import gh "../gjallarhorn"

@(test)
new_types_ddl_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, gh.sql_type(.Postgres, time.Time), "TIMESTAMPTZ")
	testing.expect_value(t, gh.sql_type(.Postgres, []u8), "BYTEA")
	testing.expect_value(t, gh.sql_type(.Postgres, gh.Uuid), "UUID")
	testing.expect_value(t, gh.sql_type(.Postgres, gh.Json), "JSONB")
}

@(test)
parse_pg_timestamp_formats :: proc(t: ^testing.T) {
	base, _ := time.components_to_time(2026, 7, 19, 14, 30, 45)

	// Plain, fractional, and zoned forms all land on the same instant when the
	// zone is UTC; a +02 offset is folded out to two hours earlier.
	plain, ok1 := gh.parse_pg_timestamp("2026-07-19 14:30:45")
	testing.expect(t, ok1)
	testing.expect_value(t, plain._nsec, base._nsec)

	frac, ok2 := gh.parse_pg_timestamp("2026-07-19 14:30:45.000000+00")
	testing.expect(t, ok2)
	testing.expect_value(t, frac._nsec, base._nsec)

	east, ok3 := gh.parse_pg_timestamp("2026-07-19 14:30:45+02")
	testing.expect(t, ok3)
	testing.expect_value(t, east._nsec, base._nsec - 2 * 3600 * 1_000_000_000)

	// A sub-second fraction is preserved (123 ms -> 123_000_000 ns).
	ms, ok4 := gh.parse_pg_timestamp("2026-07-19 14:30:45.123+00")
	testing.expect(t, ok4)
	testing.expect_value(t, ms._nsec, base._nsec + 123_000_000)

	_, bad := gh.parse_pg_timestamp("not-a-timestamp")
	testing.expect(t, !bad, "garbage is rejected")
}

@(test)
parse_bytea_roundtrip :: proc(t: ^testing.T) {
	raw := []u8{0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF}
	// bytea_text is the write side; parse_bytea is the read side — they mirror.
	text := gh.bytea_text(raw, context.temp_allocator)
	testing.expect_value(t, text, "\\xdeadbeef00ff")
	got, ok := gh.parse_bytea(text, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(got), len(raw))
	testing.expect(t, slice_eq(got, raw), "decoded bytes match")

	empty, ok2 := gh.parse_bytea("\\x", context.temp_allocator)
	testing.expect(t, ok2)
	testing.expect_value(t, len(empty), 0)
}

@(test)
encode_arg_uuid_and_json :: proc(t: ^testing.T) {
	id, err := uuid.read("550e8400-e29b-41d4-a716-446655440000")
	testing.expect_value(t, err, uuid.Read_Error.None)

	enc, ok := gh.encode_arg(gh.Uuid(id), context.temp_allocator)
	testing.expect(t, ok, "Uuid encodes")
	testing.expect_value(t, enc, "550e8400-e29b-41d4-a716-446655440000")

	jenc, jok := gh.encode_arg(gh.Json(`{"n": 42}`), context.temp_allocator)
	testing.expect(t, jok, "Json encodes verbatim")
	testing.expect_value(t, jenc, `{"n": 42}`)
}

@(test)
encode_bind_new_maybe_types :: proc(t: ^testing.T) {
	// None -> SQL NULL; Some -> the inner encoding.
	none_t: Maybe(time.Time)
	_, is_null, ok := gh.encode_bind(none_t, context.temp_allocator)
	testing.expect(t, ok && is_null, "None time.Time -> NULL")

	none_b: Maybe([]u8)
	_, bn, bok := gh.encode_bind(none_b, context.temp_allocator)
	testing.expect(t, bok && bn, "None []u8 -> NULL")

	some_b: Maybe([]u8) = []u8{0x01, 0x02}
	tb, bn2, _ := gh.encode_bind(some_b, context.temp_allocator)
	testing.expect(t, !bn2, "Some []u8 is not NULL")
	testing.expect_value(t, tb, "\\x0102")
}

@(test)
migrate_ddl_for_new_types :: proc(t: ^testing.T) {
	// The migrate path (schema_sql -> carve -> column_ddl -> sql_type) emits the
	// right Postgres column type for each new field type.
	app := gh.new(gh.Config{})
	gh.remember(&app, Typed)
	ddl := gh.schema_sql(&app, context.temp_allocator)
	testing.expect(t, strings.contains(ddl, "TIMESTAMPTZ"), "time.Time -> TIMESTAMPTZ")
	testing.expect(t, strings.contains(ddl, "BYTEA"), "[]u8 -> BYTEA")
	testing.expect(t, strings.contains(ddl, "UUID"), "Uuid -> UUID")
	testing.expect(t, strings.contains(ddl, "JSONB"), "Json -> JSONB")
}

@(test)
scan_one_preserves_null_mask :: proc(t: ^testing.T) {
	// Regression: scan_one used to slice the first row without its NULL mask, so a
	// NULL column hydrated a Maybe(T) field to Some("")/Some(0) instead of None.
	// Pure (no DB): craft a one-row result with both cells flagged NULL.
	rows := gh.Pg_Rows {
		columns = []string{"name", "count"},
		rows    = [][]string{{"", ""}},
		nulls   = [][]bool{{true, true}},
	}
	row, ok := gh.scan_one(rows, NullProbe)
	testing.expect(t, ok)
	_, has_name := row.name.?
	_, has_count := row.count.?
	testing.expect(t, !has_name, "NULL name -> None, not Some(\"\")")
	testing.expect(t, !has_count, "NULL count -> None, not Some(0)")
}

// --- DB round-trip -----------------------------------------------------------

Typed :: struct {
	id:   int       `db:"id,pk,auto"`,
	ts:   time.Time `db:"ts"`,
	blob: []u8      `db:"blob"`,
	uid:  gh.Uuid   `db:"uid"`,
	doc:  gh.Json   `db:"doc"`,
}

Nullable :: struct {
	ts:   Maybe(time.Time) `db:"ts"`,
	blob: Maybe([]u8)      `db:"blob"`,
	uid:  Maybe(gh.Uuid)   `db:"uid"`,
	doc:  Maybe(gh.Json)   `db:"doc"`,
}

@(test)
orm_types_roundtrip_against_postgres :: proc(t: ^testing.T) {
	conn: gh.Pg_Conn
	cfg := gh.Postgres_Config {
		host     = "127.0.0.1",
		port     = 5432,
		user     = "app",
		password = "secret",
		dbname   = "gjallarhorn",
	}
	if !gh.pg_open(&conn, cfg) {
		fmt.eprintln("orm_types_test: postgres unavailable; skipping DB round-trip")
		return
	}
	defer net.close(conn.sock)

	// Pin UTC so the zoneless timestamp we write is interpreted as UTC and reads
	// back on the same instant.
	gh.pg_query(&conn, "SET TIME ZONE 'UTC';", nil)
	gh.pg_query(&conn, "DROP TABLE IF EXISTS orm_probe;", nil)
	gh.pg_query(
		&conn,
		"CREATE TABLE orm_probe (id BIGSERIAL PRIMARY KEY, ts TIMESTAMPTZ, blob BYTEA, uid UUID, doc JSONB);",
		nil,
	)

	ts, _ := time.components_to_time(2026, 7, 19, 14, 30, 45)
	blob := []u8{0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF}
	uid, _ := uuid.read("550e8400-e29b-41d4-a716-446655440000")

	_, ins_ok := gh.pg_query(
		&conn,
		"INSERT INTO orm_probe (ts, blob, uid, doc) VALUES ($1, $2, $3, $4);",
		[]any{ts, blob, gh.Uuid(uid), gh.Json(`{"n": 42}`)},
	)
	testing.expect(t, ins_ok, "typed params (timestamptz/bytea/uuid/jsonb) accepted")

	rows, ok := gh.pg_query(&conn, "SELECT id, ts, blob, uid, doc FROM orm_probe;", nil)
	testing.expect(t, ok)
	row, found := gh.scan_one(rows, Typed)
	testing.expect(t, found)

	testing.expect_value(t, row.ts._nsec, ts._nsec) // timestamptz round-trips the instant
	testing.expect(t, slice_eq(row.blob, blob), "bytea round-trips exactly")
	testing.expect(t, row.uid == gh.Uuid(uid), "uuid round-trips")
	testing.expect(t, strings.contains(string(row.doc), "42"), "jsonb round-trips its value")

	// NULLs land as None on the Maybe model.
	gh.pg_query(&conn, "DELETE FROM orm_probe;", nil)
	gh.pg_query(&conn, "INSERT INTO orm_probe (ts, blob, uid, doc) VALUES (NULL, NULL, NULL, NULL);", nil)
	nrows, _ := gh.pg_query(&conn, "SELECT ts, blob, uid, doc FROM orm_probe;", nil)
	nrow, nfound := gh.scan_one(nrows, Nullable)
	testing.expect(t, nfound)
	_, has_ts := nrow.ts.?
	_, has_blob := nrow.blob.?
	_, has_uid := nrow.uid.?
	_, has_doc := nrow.doc.?
	testing.expect(t, !has_ts && !has_blob && !has_uid && !has_doc, "SQL NULL -> None for every type")

	gh.pg_query(&conn, "DROP TABLE IF EXISTS orm_probe;", nil)
}

slice_eq :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}
