package sample

import "core:strconv"
import gh "../gjallarhorn"

// (value, ok) returns, idiomatic Odin error handling.
get_handler :: proc(b: ^gh.Bifrost) {
	id, ok := gh.param_int(b, "id")
	if !ok {
		gh.text(b, 400, "id must be an integer")
		return
	}
	gh.json(b, 200, Sample{id = id, name = "thing"})
}

// POST /sample/:name — create a row. Mímir's `offer` builds the INSERT; we run
// it with `query` (not `exec`) so Postgres's RETURNING id comes back. The name
// rides in the path because the server has no request-body parser yet.
create_handler :: proc(b: ^gh.Bifrost) {
	name, ok := gh.param(b, "name")
	if !ok {
		gh.text(b, 400, "name required")
		return
	}
	w := gh.well(b)
	rows, qok := gh.query(w, gh.offer(w, Sample{name = name}))
	if !qok {
		gh.text(b, 503, "database unavailable")
		return
	}
	id := 0
	if len(rows.rows) > 0 {
		id, _ = strconv.parse_int(rows.rows[0][0]) // the RETURNING id
	}
	gh.json(b, 201, Sample{id = id, name = name})
}

// PUT /sample/:id/:name — replace a row's name by id, via Mímir's `amend`
// (UPDATE ... WHERE id = $n). Reports the command tag, e.g. "UPDATE 1".
update_handler :: proc(b: ^gh.Bifrost) {
	id, ok := gh.param_int(b, "id")
	if !ok {
		gh.text(b, 400, "id must be an integer")
		return
	}
	name, _ := gh.param(b, "name")
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
