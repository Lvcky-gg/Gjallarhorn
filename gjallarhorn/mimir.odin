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

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:reflect"


Well :: struct {
	dialect: DB_Type,
	app:     ^App,
}

well :: proc{well_from_app, well_from_bifrost}

well_from_app :: proc(app: ^App) -> Well {
	return Well{dialect = app.db_type, app = app}
}

well_from_bifrost :: proc(b: ^Bifrost) -> Well {
	return Well{dialect = b._app.db_type, app = b._app}
}

Statement :: struct {
	sql:  string,
	args: [dynamic]any,
}

Column :: struct {
	field:   string,
	name:    string,
	type_id: typeid,
	pk:      bool,
	auto:    bool,
	unique:  bool,
	notnull: bool,
}

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

remember :: proc(app: ^App, models: ..typeid) {
	for m in models {
		append(&app.models, m)
	}
}

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

migrate :: proc(app: ^App) {
	if len(app.models) == 0 {
		return
	}
	w := well(app)
	fmt.printfln("mimir: migrating %d model(s) [%v]", len(app.models), w.dialect)
	for m in app.models {
		ddl := carve(w, m)
		if app.pg.open {
			if pg_simple(&app.pg, ddl) {
				fmt.printfln("  ✓ %s", table_name(m))
			} else {
				fmt.eprintfln("  ✗ %s (see error above)", table_name(m))
			}
		} else {
			fmt.println(ddl)
		}
	}
}

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

whose :: proc(q: ^Query, condition: string, args: ..any) -> ^Query {
	append(&q.wheres, condition)
	for a in args {
		append(&q.args, a)
	}
	return q
}

order_by :: proc(q: ^Query, clause: string) -> ^Query {
	q.order = clause
	return q
}

limit :: proc(q: ^Query, n: int) -> ^Query {
	q.lim = n
	return q
}

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
// Hydration — the read side. `Pg_Rows` comes back as text cells; `scan` maps
// them onto struct fields by mapped column name (the `db:` tag, else the field
// name) and converts text to the field's type.
//
// Supported field types: int family, f32/f64, bool, string. NULL handling: the
// driver surfaces a SQL NULL as an empty cell, which converts to the field's
// zero value (0, false, ""). A column with no matching field is ignored, and a
// field with no matching column is left zero.
// ---------------------------------------------------------------------------

// scan hydrates every result row into a freshly allocated []T.
scan :: proc(rows: Pg_Rows, $T: typeid, allocator := context.temp_allocator) -> []T {
	out := make([]T, len(rows.rows), allocator)

	// Resolve each result column to its target struct field once, up front.
	cols := columns_of(T, context.temp_allocator)
	fields := make([]Maybe(reflect.Struct_Field), len(rows.columns), context.temp_allocator)
	for name, ci in rows.columns {
		for c in cols {
			if c.name == name {
				fields[ci] = reflect.struct_field_by_name(T, c.field)
				break
			}
		}
	}

	for row, ri in rows.rows {
		item: T
		base := uintptr(rawptr(&item))
		for cell, ci in row {
			f, mapped := fields[ci].?
			if !mapped {
				continue
			}
			set_field(rawptr(base + f.offset), f.type.id, cell, allocator)
		}
		out[ri] = item
	}
	return out
}

// scan_one hydrates the first result row, reporting ok=false on an empty set.
scan_one :: proc(rows: Pg_Rows, $T: typeid, allocator := context.temp_allocator) -> (T, bool) {
	if len(rows.rows) == 0 {
		return {}, false
	}
	head := Pg_Rows{columns = rows.columns, rows = rows.rows[:1]}
	return scan(head, T, allocator)[0], true
}

// set_field writes one text cell into a struct field of the given type. A value
// that fails to parse (including the empty cell from a NULL) leaves the zero.
@(private)
set_field :: proc(ptr: rawptr, id: typeid, text: string, allocator: runtime.Allocator) {
	switch id {
	case int:
		v, _ := strconv.parse_int(text);  (^int)(ptr)^ = v
	case i64:
		v, _ := strconv.parse_i64(text);  (^i64)(ptr)^ = v
	case i32:
		v, _ := strconv.parse_i64(text);  (^i32)(ptr)^ = i32(v)
	case i16:
		v, _ := strconv.parse_i64(text);  (^i16)(ptr)^ = i16(v)
	case i8:
		v, _ := strconv.parse_i64(text);  (^i8)(ptr)^ = i8(v)
	case u64:
		v, _ := strconv.parse_uint(text); (^u64)(ptr)^ = u64(v)
	case u32:
		v, _ := strconv.parse_uint(text); (^u32)(ptr)^ = u32(v)
	case u16:
		v, _ := strconv.parse_uint(text); (^u16)(ptr)^ = u16(v)
	case u8:
		v, _ := strconv.parse_uint(text); (^u8)(ptr)^ = u8(v)
	case f64:
		v, _ := strconv.parse_f64(text);  (^f64)(ptr)^ = v
	case f32:
		v, _ := strconv.parse_f32(text);  (^f32)(ptr)^ = v
	case bool:
		(^bool)(ptr)^ = parse_pg_bool(text)
	case string:
		(^string)(ptr)^ = strings.clone(text, allocator)
	}
}

// parse_pg_bool reads Postgres's text boolean ('t'/'f'), tolerating a few
// common spellings.
@(private)
parse_pg_bool :: proc(s: string) -> bool {
	switch s {
	case "t", "true", "TRUE", "True", "1", "y", "yes":
		return true
	}
	return false
}

placeholder :: proc(d: DB_Type, n: int) -> string {
	if d == .Postgres {
		return fmt.tprintf("$%d", n)
	}
	return "?"
}

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
