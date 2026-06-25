package sample

// The "M" in MVC. `db:` struct tags drive Mimir, the ORM (see
// gjallarhorn/mimir.odin): the column name, then flags. `id` is an
// auto-assigned primary key; `name` is a plain, required text column.
Sample :: struct {
	id:   int    `db:"id,pk,auto"`,
	name: string `db:"name,notnull"`,
}
