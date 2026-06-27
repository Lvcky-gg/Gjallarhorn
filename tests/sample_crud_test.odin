package tests

// sample_crud_test.odin — full CRUD round-trip for the sample app's Sample
// model against the docker Postgres, exercising the same Mímir verbs the
// sample handlers use: offer (create), recall+scan (read), amend (update),
// forget (delete). DB-gated; skips if no Postgres is reachable.
// Run with: odin test ./tests   (needs: docker compose up -d)

import "core:fmt"
import "core:net"
import "core:testing"
import gh "../gjallarhorn"
import sm "../sample"

// read a single Sample by id, mirroring get_handler's query.
read_sample :: proc(w: gh.Well, id: int) -> (sm.Sample, bool) {
	q := gh.recall(w, sm.Sample)
	gh.whose(&q, "id = ?", id)
	gh.limit(&q, 1)
	rows, ok := gh.query(w, gh.sql(&q))
	if !ok {
		return {}, false
	}
	return gh.scan_one(rows, sm.Sample)
}

@(test)
sample_crud_roundtrip :: proc(t: ^testing.T) {
	cfg := gh.Postgres_Config {
		host = "127.0.0.1", port = 5432, user = "app", password = "secret", dbname = "gjallarhorn",
	}
	app := gh.new(gh.Config{db_type = .Postgres, postgres = cfg, pool_size = 2})
	if !gh.connect(&app) {
		fmt.eprintln("sample_crud_test: postgres unavailable; skipping CRUD test")
		return
	}
	defer gh.disconnect(&app)

	gh.remember(&app, sm.Sample)
	defer delete(app.models)
	w := gh.well(&app)

	// Fresh table via the real migrate path.
	probe: gh.Pg_Conn
	gh.pg_open(&probe, cfg)
	defer net.close(probe.sock)
	gh.pg_query(&probe, "DROP TABLE IF EXISTS samples;", nil)
	gh.migrate(&app)

	// CREATE — offer builds INSERT ... RETURNING id; scan the new id back.
	ins, ins_ok := gh.query(w, gh.offer(w, sm.Sample{name = "heimdallr"}))
	testing.expect(t, ins_ok, "insert should succeed")
	created, has_id := gh.scan_one(ins, sm.Sample)
	testing.expect(t, has_id, "RETURNING id should come back")
	testing.expect(t, created.id > 0, "id should be auto-assigned")
	id := created.id

	// READ — recall the row and confirm the stored name.
	got, found := read_sample(w, id)
	testing.expect(t, found, "row should be readable")
	testing.expect_value(t, got.name, "heimdallr")

	// UPDATE — amend by primary key, then re-read.
	_, upd_ok := gh.query(w, gh.amend(w, sm.Sample{id = id, name = "loki"}))
	testing.expect(t, upd_ok, "update should succeed")
	after_update, _ := read_sample(w, id)
	testing.expect_value(t, after_update.name, "loki")

	// DELETE — forget by primary key, then confirm it's gone.
	_, del_ok := gh.query(w, gh.forget(w, sm.Sample{id = id}))
	testing.expect(t, del_ok, "delete should succeed")
	_, still_there := read_sample(w, id)
	testing.expect(t, !still_there, "row should be gone after delete")

	gh.pg_query(&probe, "DROP TABLE IF EXISTS samples;", nil)
}
