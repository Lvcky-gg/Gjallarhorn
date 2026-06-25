package gjallarhorn

// mimir.odin — Mímir, the ORM. In the myths Mímir guards the well beneath
// Yggdrasil whose water is memory; Óðinn gave an eye for a single draught. So
// here: your structs describe a shape, and Mímir remembers it as rows. The
// "M" in MVC that model.odin promised — `db:` struct tags drive everything.
//
// Naming follows the rest of gjallarhorn: a few evocative verbs, each one
// documented. Mímir's vocabulary is the well's:
//
//   carve   CREATE TABLE — carve a struct's shape into the well
//   offer   INSERT       — offer a value to the well
//   recall  SELECT       — recall rows (a Query you refine, then `sql`)
//   amend   UPDATE        — amend a remembered row by its primary key
//   forget  DELETE        — make the well forget a row by its primary key
//
// Phase note (matching the rest of the codebase's incremental honesty): Odin's
// core ships no SQL client, so Mímir's job *here* is to turn structs + tags
// into a `Statement` — parameterised SQL plus its argument list — ready to hand
// to a driver. Opening a connection and running statements is the next phase;
// the seam is `Well`, which already carries the dialect. The security
// checkpoint for this feature is SQL injection: values NEVER reach the SQL
// string. Every value is a bound parameter ($1.. for Postgres, ? otherwise).

import "core:fmt"
import "core:strings"
import "core:reflect"

// Well — a handle bound to one dialect. Today it is just the dialect; tomorrow
// it grows a socket/pool. Draw one from the app with `well`.
Well :: struct {
	dialect: DB_Type,
}

// well: draw a Well speaking the dialect chosen in Config. Take it from the app
// at setup, or from a Bifrost inside a handler — the latter reaches the app
// through the internal `_app` cursor so handlers never touch it themselves.
well :: proc{well_from_app, well_from_bifrost}

well_from_app :: proc(app: ^App) -> Well {
	return Well{dialect = app.db_type}
}

well_from_bifrost :: proc(b: ^Bifrost) -> Well {
	return Well{dialect = b._app.db_type}
}

// Statement — generated SQL and the arguments that fill its placeholders, in
// order. `args` borrow from the value passed to offer/amend/forget; use the
// Statement before that value goes out of scope.
Statement :: struct {
	sql:  string,
	args: [dynamic]any,
}

// ---------------------------------------------------------------------------
// Schema: reading `db:` tags off a struct
// ---------------------------------------------------------------------------
//
// Tag grammar:  `db:"column,flag,flag"`
//   column   the SQL column name; defaults to the field name if empty
//   flags    pk       this column is the primary key
//            auto     the database assigns it (serial / autoincrement) — Mímir
//                     never writes it on offer
//            unique   UNIQUE constraint
//            notnull  NOT NULL constraint
// A field with `db:"-"` (or no usable name) is skipped entirely.

Column :: struct {
	field:   string,  // Odin field name, used to read the value via reflection
	name:    string,  // SQL column name
	type_id: typeid,
	pk:      bool,
	auto:    bool,
	unique:  bool,
	notnull: bool,
}

// columns_of reflects a struct typeid into its mapped columns. Untagged fields
// fall back to their field name as the column; only `db:"-"` opts out.
columns_of :: proc(T: typeid, allocator := context.temp_allocator) -> []Column {
	cols := make([dynamic]Column, allocator)
	for f in reflect.struct_fields_zipped(T) {
		spec := reflect.struct_tag_get(f.tag, "db")
		if spec == "-" {
			continue
		}

		col := Column{field = f.name, name = f.name, type_id = f.type.id}
		if spec != "" {
			parts := strings.split(spec, ",", context.temp_allocator)
			if parts[0] != "" {
				col.name = parts[0]
			}
			for flag in parts[1:] {
				switch strings.trim_space(flag) {
				case "pk":      col.pk = true
				case "auto":    col.auto = true
				case "unique":  col.unique = true
				case "notnull": col.notnull = true
				}
			}
		}
		append(&cols, col)
	}
	return cols[:]
}

// table_name derives the table from the struct's name: `Sample` -> "samples".
// Lowercased and naively pluralised — predictable, and good enough until an
// explicit override is wanted.
table_name :: proc(T: typeid, allocator := context.temp_allocator) -> string {
	name := "rows"
	ti := type_info_of(T)
	if named, ok := ti.variant.(reflect.Type_Info_Named); ok {
		name = named.name
	}
	lower := strings.to_lower(name, allocator)
	if strings.has_suffix(lower, "s") {
		return lower
	}
	return strings.concatenate({lower, "s"}, allocator)
}

// ---------------------------------------------------------------------------
// carve — CREATE TABLE
// ---------------------------------------------------------------------------

// carve emits the CREATE TABLE DDL for a struct in the Well's dialect.
carve :: proc(w: Well, T: typeid, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "CREATE TABLE IF NOT EXISTS %s (\n", table_name(T, allocator))

	cols := columns_of(T, allocator)
	for col, i in cols {
		fmt.sbprintf(&b, "  %s %s", col.name, column_ddl(w.dialect, col))
		if i < len(cols) - 1 {
			strings.write_string(&b, ",")
		}
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, ");")
	return strings.to_string(b)
}

// column_ddl renders one column's type and constraints. An `auto` primary key
// becomes the dialect's autoincrement form and folds PRIMARY KEY into itself.
column_ddl :: proc(d: DB_Type, col: Column) -> string {
	if col.pk && col.auto {
		switch d {
		case .Postgres: return "BIGSERIAL PRIMARY KEY"
		case .MySQL:    return "BIGINT AUTO_INCREMENT PRIMARY KEY"
		case .SQLite:   return "INTEGER PRIMARY KEY AUTOINCREMENT"
		}
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, sql_type(d, col.type_id))
	if col.pk {
		strings.write_string(&sb, " PRIMARY KEY")
	}
	if col.unique {
		strings.write_string(&sb, " UNIQUE")
	}
	if col.notnull && !col.pk {
		strings.write_string(&sb, " NOT NULL")
	}
	return strings.to_string(sb)
}

// sql_type maps an Odin type to a column type per dialect. Unknown types fall
// back to TEXT — Mímir would rather store something than refuse the shape.
sql_type :: proc(d: DB_Type, id: typeid) -> string {
	switch id {
	case int, i64, i32, i16, i8, u64, u32, u16, u8:
		switch d {
		case .Postgres: return "BIGINT"
		case .MySQL:    return "BIGINT"
		case .SQLite:   return "INTEGER"
		}
	case f32, f64:
		switch d {
		case .Postgres: return "DOUBLE PRECISION"
		case .MySQL:    return "DOUBLE"
		case .SQLite:   return "REAL"
		}
	case bool:
		switch d {
		case .Postgres: return "BOOLEAN"
		case .MySQL:    return "TINYINT(1)"
		case .SQLite:   return "INTEGER"
		}
	case string:
		switch d {
		case .MySQL:               return "VARCHAR(255)"
		case .Postgres, .SQLite:   return "TEXT"
		}
	}
	return "TEXT"
}

// ---------------------------------------------------------------------------
// remember / migrate — schema, derived from your models, applied for you
// ---------------------------------------------------------------------------
//
// The "auto-magic": you never write a CREATE TABLE. You hand Mímir your model
// types once with `remember`, and `migrate` carves every one of them. `run`
// calls `migrate` at startup, so defining a tagged struct and remembering it is
// the whole ceremony — the table follows from the shape.

// remember: register one or more model types so Mímir migrates them at startup.
// Call it from your package's register proc, e.g. remember(app, Sample, User).
remember :: proc(app: ^App, models: ..typeid) {
	for m in models {
		append(&app.models, m)
	}
}

// schema_sql concatenates the CREATE TABLE DDL for every remembered model, in
// registration order. Handy for writing a migration file or inspecting it.
schema_sql :: proc(app: ^App, allocator := context.temp_allocator) -> string {
	w := well(app)
	b := strings.builder_make(allocator)
	for m, i in app.models {
		if i > 0 {
			strings.write_string(&b, "\n\n")
		}
		strings.write_string(&b, carve(w, m, allocator))
	}
	return strings.to_string(b)
}

// migrate derives and applies the schema for every remembered model. Each table
// is `CREATE TABLE IF NOT EXISTS`, so re-running is safe. Without a live
// connection (the deferred phase) it emits the DDL it would execute; once Well
// grows a socket, swap the print for an exec — the call site here doesn't change.
migrate :: proc(app: ^App) {
	if len(app.models) == 0 {
		return
	}
	w := well(app)
	fmt.printfln("mimir: migrating %d model(s) [%v]", len(app.models), w.dialect)
	for m in app.models {
		ddl := carve(w, m)
		if app.pg.open {
			// Live connection: run the DDL. CREATE TABLE IF NOT EXISTS is idempotent.
			if pg_simple(&app.pg, ddl) {
				fmt.printfln("  ✓ %s", table_name(m))
			} else {
				fmt.eprintfln("  ✗ %s (see error above)", table_name(m))
			}
		} else {
			// Offline: print the DDL Mímir would execute.
			fmt.println(ddl)
		}
	}
}

// ---------------------------------------------------------------------------
// offer — INSERT
// ---------------------------------------------------------------------------

// offer builds an INSERT for a value. `auto` columns are left to the database.
// Postgres statements carry a RETURNING clause for the primary key.
offer :: proc(w: Well, value: any, allocator := context.temp_allocator) -> Statement {
	cols := columns_of(value.id, allocator)
	stmt := Statement{args = make([dynamic]any, allocator)}

	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "INSERT INTO %s (", table_name(value.id, allocator))

	n := 1
	names := strings.builder_make(allocator)
	vals := strings.builder_make(allocator)
	pk_name := ""
	for col in cols {
		if col.pk {
			pk_name = col.name
		}
		if col.auto {
			continue
		}
		if n > 1 {
			strings.write_string(&names, ", ")
			strings.write_string(&vals, ", ")
		}
		strings.write_string(&names, col.name)
		strings.write_string(&vals, placeholder(w.dialect, n))
		append(&stmt.args, reflect.struct_field_value_by_name(value, col.field))
		n += 1
	}

	fmt.sbprintf(&b, "%s) VALUES (%s)", strings.to_string(names), strings.to_string(vals))
	if w.dialect == .Postgres && pk_name != "" {
		fmt.sbprintf(&b, " RETURNING %s", pk_name)
	}
	strings.write_string(&b, ";")

	stmt.sql = strings.to_string(b)
	return stmt
}

// ---------------------------------------------------------------------------
// amend / forget — UPDATE and DELETE by primary key
// ---------------------------------------------------------------------------

// amend builds an UPDATE that writes every non-pk, non-auto column of `value`,
// keyed on its primary key. The pk value is the final bound argument.
amend :: proc(w: Well, value: any, allocator := context.temp_allocator) -> Statement {
	cols := columns_of(value.id, allocator)
	stmt := Statement{args = make([dynamic]any, allocator)}

	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "UPDATE %s SET ", table_name(value.id, allocator))

	n := 1
	pk: Column
	have_pk := false
	for col in cols {
		if col.pk {
			pk, have_pk = col, true
			continue
		}
		if col.auto {
			continue
		}
		if n > 1 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "%s = %s", col.name, placeholder(w.dialect, n))
		append(&stmt.args, reflect.struct_field_value_by_name(value, col.field))
		n += 1
	}

	if have_pk {
		fmt.sbprintf(&b, " WHERE %s = %s", pk.name, placeholder(w.dialect, n))
		append(&stmt.args, reflect.struct_field_value_by_name(value, pk.field))
	}
	strings.write_string(&b, ";")

	stmt.sql = strings.to_string(b)
	return stmt
}

// forget builds a DELETE keyed on the value's primary key.
forget :: proc(w: Well, value: any, allocator := context.temp_allocator) -> Statement {
	cols := columns_of(value.id, allocator)
	stmt := Statement{args = make([dynamic]any, allocator)}

	for col in cols {
		if col.pk {
			stmt.sql = fmt.aprintf(
				"DELETE FROM %s WHERE %s = %s;",
				table_name(value.id, allocator), col.name, placeholder(w.dialect, 1),
				allocator = allocator,
			)
			append(&stmt.args, reflect.struct_field_value_by_name(value, col.field))
			break
		}
	}
	return stmt
}

// ---------------------------------------------------------------------------
// recall — SELECT, a small fluent builder
// ---------------------------------------------------------------------------

// Query accumulates SELECT clauses. Build it with recall, refine with where /
// order_by / limit, then materialise with `sql`.
Query :: struct {
	dialect: DB_Type,
	table:   string,
	columns: string,        // comma-joined column list
	wheres:  [dynamic]string, // condition templates, joined by AND; use ? for binds
	args:    [dynamic]any,
	order:   string,
	lim:     int, // 0 = no limit
}

// recall begins a SELECT over a struct's mapped columns.
recall :: proc(w: Well, T: typeid, allocator := context.temp_allocator) -> Query {
	cols := columns_of(T, allocator)
	names := make([dynamic]string, allocator)
	for col in cols {
		append(&names, col.name)
	}
	return Query{
		dialect = w.dialect,
		table   = table_name(T, allocator),
		columns = strings.join(names[:], ", ", allocator),
		wheres  = make([dynamic]string, allocator),
		args    = make([dynamic]any, allocator),
	}
}

// whose adds a condition (`where` is an Odin keyword). Write binds as `?`; they
// are renumbered per dialect when rendered. Conditions combine with AND.
whose :: proc(q: ^Query, condition: string, args: ..any) -> ^Query {
	append(&q.wheres, condition)
	for a in args {
		append(&q.args, a)
	}
	return q
}

// order_by sets the ORDER BY clause, e.g. order_by(&q, "name DESC").
order_by :: proc(q: ^Query, clause: string) -> ^Query {
	q.order = clause
	return q
}

// limit caps the row count. A limit of 0 means unbounded.
limit :: proc(q: ^Query, n: int) -> ^Query {
	q.lim = n
	return q
}

// sql renders the Query into a Statement, numbering placeholders for the
// dialect across every `?` in the accumulated WHERE conditions.
sql :: proc(q: ^Query, allocator := context.temp_allocator) -> Statement {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "SELECT %s FROM %s", q.columns, q.table)

	if len(q.wheres) > 0 {
		strings.write_string(&b, " WHERE ")
		idx := 1
		for cond, i in q.wheres {
			if i > 0 {
				strings.write_string(&b, " AND ")
			}
			rendered, next := render_binds(cond, q.dialect, idx, allocator)
			strings.write_string(&b, rendered)
			idx = next
		}
	}
	if q.order != "" {
		fmt.sbprintf(&b, " ORDER BY %s", q.order)
	}
	if q.lim > 0 {
		fmt.sbprintf(&b, " LIMIT %d", q.lim)
	}
	strings.write_string(&b, ";")

	stmt := Statement{sql = strings.to_string(b), args = make([dynamic]any, allocator)}
	for a in q.args {
		append(&stmt.args, a)
	}
	return stmt
}

// ---------------------------------------------------------------------------
// Placeholders — the injection-proof seam
// ---------------------------------------------------------------------------

// placeholder is the nth bind marker in the dialect: $n for Postgres (where
// order matters), ? for MySQL and SQLite.
placeholder :: proc(d: DB_Type, n: int) -> string {
	if d == .Postgres {
		return fmt.tprintf("$%d", n)
	}
	return "?"
}

// render_binds rewrites each `?` in a condition template to the dialect marker,
// continuing the numbering from `start`. Returns the rendered string and the
// next free index.
render_binds :: proc(s: string, d: DB_Type, start: int, allocator := context.temp_allocator) -> (string, int) {
	if d != .Postgres {
		return strings.clone(s, allocator), start
	}
	b := strings.builder_make(allocator)
	n := start
	for r in s {
		if r == '?' {
			fmt.sbprintf(&b, "$%d", n)
			n += 1
		} else {
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b), n
}
