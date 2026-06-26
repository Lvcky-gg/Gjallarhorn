package tests

// fk_test.odin — foreign-key DDL and join queries (GH-025). The DDL/SQL tests
// are pure; the enforcement test round-trips through the docker Postgres and
// skips if none is reachable.
// Run with: odin test ./tests   (DB test needs: docker compose up -d)

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

// table_name -> "fkparents"
FkParent :: struct {
	id: int `db:"id,pk"`,
}

// table_name -> "fkchilds"; parent_id references fkparents(id)
FkChild :: struct {
	id:        int `db:"id,pk"`,
	parent_id: int `db:"parent_id,fk:fkparents.id"`,
}

@(test)
fk_tag_emits_reference :: proc(t: ^testing.T) {
	ddl := gh.carve(gh.Well{dialect = .Postgres}, FkChild)
	testing.expect(
		t,
		strings.contains(ddl, "parent_id BIGINT REFERENCES fkparents(id)"),
		"fk tag should emit a REFERENCES constraint",
	)
}

@(test)
join_clause_renders :: proc(t: ^testing.T) {
	q := gh.recall(gh.Well{dialect = .Postgres}, FkChild)
	gh.join(&q, "JOIN fkparents ON fkparents.id = fkchilds.parent_id")
	gh.whose(&q, "fkparents.id = ?", 5)
	stmt := gh.sql(&q)

	testing.expect(t, strings.contains(stmt.sql, "FROM fkchilds JOIN fkparents ON"), "JOIN sits after FROM")
	testing.expect(t, strings.contains(stmt.sql, "WHERE fkparents.id = $1"), "binds still number from $1")
}

@(test)
fk_enforced_by_postgres :: proc(t: ^testing.T) {
	cfg := gh.Postgres_Config {
		host     = "127.0.0.1",
		port     = 5432,
		user     = "app",
		password = "secret",
		dbname   = "gjallarhorn",
	}
	app := gh.new(gh.Config{db_type = .Postgres, postgres = cfg, pool_size = 1})
	if !gh.connect(&app) {
		fmt.eprintln("fk_test: postgres unavailable; skipping FK enforcement test")
		return
	}
	defer gh.disconnect(&app)
	w := gh.well(&app)

	probe: gh.Pg_Conn
	gh.pg_open(&probe, cfg)
	defer net.close(probe.sock)

	// child first (FK dependency), then parent.
	gh.pg_query(&probe, "DROP TABLE IF EXISTS fkchilds;", nil)
	gh.pg_query(&probe, "DROP TABLE IF EXISTS fkparents;", nil)

	// Create both tables from Mímir's carve output, exercising the emitted FK.
	gh.pg_query(&probe, gh.carve(w, FkParent), nil)
	gh.pg_query(&probe, gh.carve(w, FkChild), nil)

	// Referencing a non-existent parent must be rejected by the FK.
	_, bad := gh.pg_query(&probe, "INSERT INTO fkchilds (id, parent_id) VALUES (1, 999);", nil)
	testing.expect(t, !bad, "FK should reject an orphan child")

	// With the parent present, the same child inserts cleanly.
	gh.pg_query(&probe, "INSERT INTO fkparents (id) VALUES (1);", nil)
	_, good := gh.pg_query(&probe, "INSERT INTO fkchilds (id, parent_id) VALUES (2, 1);", nil)
	testing.expect(t, good, "a child with a valid parent is accepted")

	gh.pg_query(&probe, "DROP TABLE IF EXISTS fkchilds;", nil)
	gh.pg_query(&probe, "DROP TABLE IF EXISTS fkparents;", nil)
}
