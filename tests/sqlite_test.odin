package tests

// sqlite_test.odin — the optional SQLite backend (sqlite.odin). These run only
// in a `-define:GJ_SQLITE=true` build; a default build's stub connect() returns
// false, so they skip (like the Postgres tests without a DB). An in-memory DB
// means no external server. Run with: odin test ./tests -define:GJ_SQLITE=true

import "core:testing"
import gh "../gjallarhorn"

Widget :: struct {
	id:    int          `db:"id,pk,auto"`,
	name:  string       `db:"name,notnull"`,
	price: f64          `db:"price"`,
	note:  Maybe(string) `db:"note"`,
}

@(test)
sqlite_crud_roundtrip :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{db_type = .SQLite, sqlite = ":memory:"})
	if !gh.connect(&app) {
		return // default build (stubs) or no libsqlite3 — skip
	}
	defer gh.disconnect(&app)
	gh.remember(&app, Widget)
	gh.migrate(&app) // creates the table over the live handle

	w := gh.well(&app)

	// INSERT via offer (no RETURNING on SQLite) + last_insert_rowid.
	ok := gh.exec(w, gh.offer(w, Widget{name = "hammer", price = 9.5}))
	testing.expect(t, ok, "insert succeeds")
	ok2 := gh.exec(w, gh.offer(w, Widget{name = "nail", price = 0.1}))
	testing.expect(t, ok2)

	// SELECT + scan into structs, with a WHERE bind (? placeholder for SQLite).
	q := gh.recall(w, Widget)
	gh.whose(&q, "price > ?", 1.0)
	gh.order_by(&q, "price DESC")
	rows, qok := gh.query(w, gh.sql(&q))
	testing.expect(t, qok, "select succeeds")
	got := gh.scan(rows, Widget)
	testing.expect_value(t, len(got), 1) // only the hammer is > 1.0
	testing.expect_value(t, got[0].name, "hammer")
	testing.expect_value(t, got[0].price, 9.5)

	// A NULL column hydrates a Maybe(T) field to None, not "".
	one, found := gh.scan_one(rows, Widget)
	testing.expect(t, found)
	_, has_note := one.note.?
	testing.expect(t, !has_note, "unset note is None")
}

@(test)
sqlite_null_distinct_from_empty :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{db_type = .SQLite, sqlite = ":memory:"})
	if !gh.connect(&app) {
		return
	}
	defer gh.disconnect(&app)
	gh.remember(&app, Widget)
	gh.migrate(&app)
	w := gh.well(&app)

	// One row with an explicit empty-string note, one with a real NULL.
	some_empty: Maybe(string) = ""
	gh.exec(w, gh.offer(w, Widget{name = "a", note = some_empty})) // Some("")
	gh.exec(w, gh.offer(w, Widget{name = "b"})) // note left None -> NULL

	q := gh.recall(w, Widget)
	gh.order_by(&q, "name")
	rows, _ := gh.query(w, gh.sql(&q))
	got := gh.scan(rows, Widget)
	testing.expect_value(t, len(got), 2)

	ev, has_a := got[0].note.? // "a": Some("")
	testing.expect(t, has_a, "empty string is Some, not None")
	testing.expect_value(t, ev, "")
	_, has_b := got[1].note.? // "b": None
	testing.expect(t, !has_b, "NULL is None, not empty")
}

sqlite_tx_app: ^gh.App // handed to the tx closures (Odin has no captures)
tx_two_inserts :: proc(w: gh.Well) -> bool {
	a := gh.exec(w, gh.offer(w, Widget{name = "tx-a", price = 1}))
	b := gh.exec(w, gh.offer(w, Widget{name = "tx-b", price = 2}))
	return a && b
}
tx_insert_then_fail :: proc(w: gh.Well) -> bool {
	gh.exec(w, gh.offer(w, Widget{name = "doomed", price = 3}))
	return false // signals rollback
}

sqlite_count :: proc(w: gh.Well) -> int {
	rows, _ := gh.query(w, gh.Statement{sql = "SELECT count(*) FROM widgets;"})
	if len(rows.rows) == 0 {return -1}
	n := 0
	for c in rows.rows[0][0] {n = n * 10 + int(c - '0')}
	return n
}

@(test)
sqlite_transactions :: proc(t: ^testing.T) {
	app := gh.new(gh.Config{db_type = .SQLite, sqlite = ":memory:"})
	if !gh.connect(&app) {
		return
	}
	defer gh.disconnect(&app)
	gh.remember(&app, Widget)
	gh.migrate(&app)
	w := gh.well(&app)

	// A committing tx persists both rows.
	testing.expect(t, gh.tx(w, tx_two_inserts), "tx commits")
	testing.expect_value(t, sqlite_count(w), 2)

	// A tx that returns false rolls its work back — the doomed row never lands.
	testing.expect(t, !gh.tx(w, tx_insert_then_fail), "tx reports failure")
	testing.expect_value(t, sqlite_count(w), 2) // still 2, not 3
}

@(test)
sqlite_migrate_adds_columns :: proc(t: ^testing.T) {
	// PRAGMA table_info diff: a table created without a column gains it on the
	// next migrate.
	app := gh.new(gh.Config{db_type = .SQLite, sqlite = ":memory:"})
	if !gh.connect(&app) {
		return
	}
	defer gh.disconnect(&app)
	w := gh.well(&app)

	gh.exec(w, gh.Statement{sql = "CREATE TABLE widgets (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);"})
	gh.remember(&app, Widget) // model has price + note the table lacks
	gh.migrate(&app) // should ALTER them in

	// Inserting the full shape now works, proving the columns were added.
	ok := gh.exec(w, gh.offer(w, Widget{name = "x", price = 2.0}))
	testing.expect(t, ok, "insert with the added columns succeeds")
}
