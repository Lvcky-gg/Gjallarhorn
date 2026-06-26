package sample

import "core:fmt"
import "core:strconv"
import gh "../gjallarhorn"

// GET /sample/:id — recall a single row by id and hydrate it back into a
// Sample with Mímir's `scan_one`, rather than echoing a hardcoded value.
get_handler :: proc(b: ^gh.Bifrost) {
	id, ok := gh.param_int(b, "id")
	if !ok {
		gh.text(b, 400, "id must be an integer")
		return
	}

	w := gh.well(b)
	q := gh.recall(w, Sample)
	gh.whose(&q, "id = ?", id)
	gh.limit(&q, 1)

	rows, qok := gh.query(w, gh.sql(&q))
	if !qok {
		gh.text(b, 503, "database unavailable")
		return
	}

	row, found := gh.scan_one(rows, Sample)
	if !found {
		gh.not_found(b)
		return
	}
	gh.json(b, 200, row)
}

// POST /sample — create a row from a JSON body, e.g. {"name":"thing"}. Mímir's
// `offer` builds the INSERT; we run it with `query` (not `exec`) so Postgres's
// RETURNING id comes back.
create_handler :: proc(b: ^gh.Bifrost) {
	payload: Sample
	if !gh.bind_json(b, &payload) {
		return // bind_json already wrote the 400
	}
	if payload.name == "" {
		gh.text(b, 400, "name required")
		return
	}
	w := gh.well(b)
	rows, qok := gh.query(w, gh.offer(w, Sample{name = payload.name}))
	if !qok {
		// Distinguish a server-side error (with a SQLSTATE) from the DB being
		// unreachable, so the client learns *why* it failed.
		if gh.failed(rows) {
			gh.text(b, 400, fmt.tprintf("database error %s: %s", rows.err.code, rows.err.message))
		} else {
			gh.text(b, 503, "database unavailable")
		}
		return
	}
	id := 0
	if len(rows.rows) > 0 {
		id, _ = strconv.parse_int(rows.rows[0][0]) // the RETURNING id
	}
	gh.json(b, 201, Sample{id = id, name = payload.name})
}

// PUT /sample/:id — replace a row's name by id. The id rides in the path; the
// new name comes from a JSON body, e.g. {"name":"renamed"}. Uses Mímir's `amend`
// (UPDATE ... WHERE id = $n) and reports the command tag, e.g. "UPDATE 1".
update_handler :: proc(b: ^gh.Bifrost) {
	id, ok := gh.param_int(b, "id")
	if !ok {
		gh.text(b, 400, "id must be an integer")
		return
	}
	payload: Sample
	if !gh.bind_json(b, &payload) {
		return
	}
	name := payload.name
	w := gh.well(b)
	rows, qok := gh.query(w, gh.amend(w, Sample{id = id, name = name}))
	if !qok {
		gh.text(b, 503, "database unavailable")
		return
	}
	gh.json(b, 200, struct {
		updated: string,
	}{updated = rows.tag})
}

// DELETE /sample/:id — remove a row by id, via Mímir's `forget`
// (DELETE FROM ... WHERE id = $1). Reports the command tag, e.g. "DELETE 1".
delete_handler :: proc(b: ^gh.Bifrost) {
	id, ok := gh.param_int(b, "id")
	if !ok {
		gh.text(b, 400, "id must be an integer")
		return
	}
	w := gh.well(b)
	rows, qok := gh.query(w, gh.forget(w, Sample{id = id}))
	if !qok {
		gh.text(b, 503, "database unavailable")
		return
	}
	gh.json(b, 200, struct {
		deleted: string,
	}{deleted = rows.tag})
}

// schema_handler shows Mimir at work: the CREATE TABLE it carves for Sample,
// plus the parameterised SQL it would run to recall and to offer a row — values
// never touch the SQL string, only the args list.
schema_handler :: proc(b: ^gh.Bifrost) {
	w := gh.well(b)

	row := Sample{id = 7, name = "thing"}
	q := gh.recall(w, Sample)
	gh.whose(&q, "id = ?", row.id)
	gh.limit(&q, 1)
	find := gh.sql(&q)
	insert := gh.offer(w, row)

	gh.json(b, 200, struct {
		ddl:    string,
		recall: string,
		offer:  string,
	}{
		ddl    = gh.carve(w, Sample),
		recall = find.sql,
		offer  = insert.sql,
	})
}
