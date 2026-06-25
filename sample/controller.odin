package sample

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
