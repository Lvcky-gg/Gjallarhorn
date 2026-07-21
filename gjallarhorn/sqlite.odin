package gjallarhorn

// sqlite.odin — an optional live SQLite backend for Mímir, so query/exec run
// against SQLite as well as Postgres. Like TLS, it is opt-in behind a build flag
// (`-define:GJ_SQLITE=true`) and links the system libsqlite3, so a default build
// stays dependency-free. Odin ships no SQLite binding, so this foreign-imports
// the dozen functions the ORM needs.
//
//   app := gh.new(gh.Config{ db_type = .SQLite, sqlite = "app.db" })  // or ":memory:"
//   odin build . -define:GJ_SQLITE=true
//
// Mímir already generates SQLite DDL and `?` placeholders (dialect-aware), and
// `scan` reads text cells, so this layer only opens a connection, binds args as
// text, and marshals result rows into a Pg_Rows the rest of the ORM consumes.
// The single connection is mutex-guarded (app.sqlite_mu), so workers serialize on
// it — fine for SQLite, whose writes serialize regardless.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"

GJ_SQLITE :: #config(GJ_SQLITE, false)

// sqlite_migrate carves each remembered model and ALTERs in any new columns,
// mirroring the Postgres migrate path but over PRAGMA table_info. Called from
// migrate() when db_type is .SQLite.
sqlite_migrate :: proc(app: ^App) {
	pretty := stream_color(.Info)
	w := well(app)
	for m in app.models {
		table := table_name(m)
		if !sqlite_exec_sql(app, carve(w, m), nil) {
			logft(.Error, "mimir", "sqlite: create %s failed", table)
			continue
		}
		added := sqlite_add_missing_columns(app, w, m, table)
		fmt.printfln("  %s %s (+%d column(s))", paint(pretty, "\e[1;32m", "✓"), table, added)
	}
}

// sqlite_add_missing_columns diffs the model against PRAGMA table_info and adds
// any missing (non-auto) column, the SQLite twin of add_missing_columns.
sqlite_add_missing_columns :: proc(app: ^App, w: Well, T: typeid, table: string) -> int {
	rows, ok := sqlite_query_sql(
		app,
		fmt.tprintf("PRAGMA table_info(%s);", table),
		nil,
		context.temp_allocator,
	)
	if !ok {
		return 0
	}
	existing := make(map[string]bool, context.temp_allocator)
	name_col := 1 // PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
	for row in rows.rows {
		if len(row) > name_col {
			existing[row[name_col]] = true
		}
	}
	added := 0
	for col in columns_of(T, context.temp_allocator) {
		if col.auto || col.name in existing {
			continue
		}
		alter := fmt.tprintf("ALTER TABLE %s ADD COLUMN %s %s;", table, col.name, sql_type(.SQLite, col.type_id))
		if sqlite_exec_sql(app, alter, nil) {
			added += 1
		}
	}
	return added
}

when GJ_SQLITE {

	foreign import sqlite3 "system:sqlite3"

	SQLITE_OK :: 0
	SQLITE_ROW :: 100
	SQLITE_DONE :: 101
	SQLITE_NULL :: 5
	SQLITE_OPEN_READWRITE :: 0x00000002
	SQLITE_OPEN_CREATE :: 0x00000004
	SQLITE_OPEN_FULLMUTEX :: 0x00010000 // serialized threading mode

	// SQLITE_TRANSIENT tells SQLite to copy bound text immediately, so our temp
	// buffers needn't outlive the bind call.
	SQLITE_TRANSIENT := rawptr(~uintptr(0)) // (void*)-1

	foreign sqlite3 {
		sqlite3_open_v2 :: proc(filename: cstring, ppDb: ^rawptr, flags: i32, zVfs: cstring) -> i32 ---
		sqlite3_close :: proc(db: rawptr) -> i32 ---
		sqlite3_errmsg :: proc(db: rawptr) -> cstring ---
		sqlite3_prepare_v2 :: proc(db: rawptr, sql: cstring, n: i32, ppStmt: ^rawptr, pzTail: ^cstring) -> i32 ---
		sqlite3_bind_text :: proc(stmt: rawptr, idx: i32, text: cstring, n: i32, destr: rawptr) -> i32 ---
		sqlite3_bind_null :: proc(stmt: rawptr, idx: i32) -> i32 ---
		sqlite3_step :: proc(stmt: rawptr) -> i32 ---
		sqlite3_column_count :: proc(stmt: rawptr) -> i32 ---
		sqlite3_column_name :: proc(stmt: rawptr, i: i32) -> cstring ---
		sqlite3_column_text :: proc(stmt: rawptr, i: i32) -> cstring ---
		sqlite3_column_type :: proc(stmt: rawptr, i: i32) -> i32 ---
		sqlite3_finalize :: proc(stmt: rawptr) -> i32 ---
		sqlite3_changes :: proc(db: rawptr) -> i32 ---
		sqlite3_last_insert_rowid :: proc(db: rawptr) -> i64 ---
	}

	// sqlite_open opens (creating if absent) the configured database in serialized
	// mode, so the single handle is safe across worker threads.
	sqlite_open :: proc(app: ^App) -> bool {
		path := app.sqlite_path == "" ? ":memory:" : app.sqlite_path
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		db: rawptr
		flags := i32(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
		if sqlite3_open_v2(cpath, &db, flags, nil) != SQLITE_OK {
			logft(.Error, "mimir", "sqlite: cannot open %q: %s", path, sqlite3_errmsg(db))
			if db != nil {sqlite3_close(db)}
			return false
		}
		app.sqlite = db
		return true
	}

	sqlite_close :: proc(app: ^App) {
		if app.sqlite != nil {
			sqlite3_close(app.sqlite)
			app.sqlite = nil
		}
	}

	// sqlite_exec / sqlite_query lock the single connection, unless `locked` (a tx
	// already holds app.sqlite_mu — sync.Mutex is not re-entrant).
	sqlite_exec :: proc(app: ^App, stmt: Statement, locked := false) -> bool {
		if !locked {sync.lock(&app.sqlite_mu)}
		defer if !locked {sync.unlock(&app.sqlite_mu)}
		return sqlite_exec_sql(app, stmt.sql, stmt.args[:])
	}

	sqlite_query :: proc(app: ^App, stmt: Statement, locked := false, allocator := context.temp_allocator) -> (Pg_Rows, bool) {
		if !locked {sync.lock(&app.sqlite_mu)}
		defer if !locked {sync.unlock(&app.sqlite_mu)}
		return sqlite_query_sql(app, stmt.sql, stmt.args[:], allocator)
	}

	// sqlite_tx runs body between BEGIN/COMMIT on the single connection, holding
	// the mutex for the whole transaction; body's statements see sqlite_locked.
	sqlite_tx :: proc(app: ^App, w: Well, body: Tx_Body) -> bool {
		sync.lock(&app.sqlite_mu)
		defer sync.unlock(&app.sqlite_mu)
		if !sqlite_exec_sql(app, "BEGIN", nil) {
			return false
		}
		tw := w
		tw.sqlite_locked = true
		if body(tw) {
			return sqlite_exec_sql(app, "COMMIT", nil)
		}
		sqlite_exec_sql(app, "ROLLBACK", nil)
		return false
	}

	// sqlite_prepare_bind compiles `sql` and binds `args` positionally as text (a
	// nil any binds SQL NULL). Caller finalizes the returned statement.
	sqlite_prepare_bind :: proc(app: ^App, sql: string, args: []any) -> (rawptr, bool) {
		csql := strings.clone_to_cstring(sql, context.temp_allocator)
		st: rawptr
		if sqlite3_prepare_v2(app.sqlite, csql, -1, &st, nil) != SQLITE_OK {
			logft(.Error, "mimir", "sqlite: %s", sqlite3_errmsg(app.sqlite))
			return nil, false
		}
		for a, i in args {
			idx := i32(i + 1)
			text, is_null, ok := encode_bind(a, context.temp_allocator)
			if !ok {
				logft(.Error, "mimir", "sqlite: cannot encode bind arg $%d", i + 1)
				sqlite3_finalize(st)
				return nil, false
			}
			if is_null {
				sqlite3_bind_null(st, idx)
			} else {
				sqlite3_bind_text(st, idx, strings.clone_to_cstring(text, context.temp_allocator), -1, SQLITE_TRANSIENT)
			}
		}
		return st, true
	}

	// sqlite_exec_sql runs a statement that returns no rows (or whose rows we
	// ignore). Assumes the caller holds app.sqlite_mu.
	sqlite_exec_sql :: proc(app: ^App, sql: string, args: []any) -> bool {
		st, ok := sqlite_prepare_bind(app, sql, args)
		if !ok {
			return false
		}
		defer sqlite3_finalize(st)
		rc := sqlite3_step(st)
		return rc == SQLITE_DONE || rc == SQLITE_ROW
	}

	// sqlite_query_sql runs a statement and marshals its rows into a Pg_Rows the
	// ORM's scan already understands (text cells + a NULL mask). Assumes the
	// caller holds app.sqlite_mu.
	sqlite_query_sql :: proc(app: ^App, sql: string, args: []any, allocator: runtime.Allocator) -> (Pg_Rows, bool) {
		st, ok := sqlite_prepare_bind(app, sql, args)
		if !ok {
			return {}, false
		}
		defer sqlite3_finalize(st)

		ncol := int(sqlite3_column_count(st))
		out: Pg_Rows
		cols := make([]string, ncol, allocator)
		for i in 0 ..< ncol {
			cols[i] = strings.clone(string(sqlite3_column_name(st, i32(i))), allocator)
		}
		out.columns = cols

		rows := make([dynamic][]string, allocator)
		nulls := make([dynamic][]bool, allocator)
		for sqlite3_step(st) == SQLITE_ROW {
			row := make([]string, ncol, allocator)
			null_row := make([]bool, ncol, allocator)
			for i in 0 ..< ncol {
				if sqlite3_column_type(st, i32(i)) == SQLITE_NULL {
					null_row[i] = true
				} else {
					row[i] = strings.clone(string(sqlite3_column_text(st, i32(i))), allocator)
				}
			}
			append(&rows, row)
			append(&nulls, null_row)
		}
		out.rows = rows[:]
		out.nulls = nulls[:]
		// A synthetic tag so callers that read rows.tag (e.g. "UPDATE 1") still work.
		out.tag = fmt.aprintf("OK %d", sqlite3_changes(app.sqlite), allocator = allocator)
		return out, true
	}

	// sqlite_last_id returns the rowid of the last insert — SQLite's stand-in for
	// Postgres's RETURNING id.
	sqlite_last_id :: proc(app: ^App) -> i64 {
		return sqlite3_last_insert_rowid(app.sqlite)
	}

} else {
	// Stubs so the package compiles without libsqlite3. Selecting db_type = .SQLite
	// in a default build fails loudly at connect().
	sqlite_open :: proc(app: ^App) -> bool {
		logft(.Error, "mimir", "SQLite support needs a -define:GJ_SQLITE=true build")
		return false
	}
	sqlite_close :: proc(app: ^App) {}
	sqlite_exec :: proc(app: ^App, stmt: Statement, locked := false) -> bool {return false}
	sqlite_query :: proc(app: ^App, stmt: Statement, locked := false, allocator := context.temp_allocator) -> (Pg_Rows, bool) {return {}, false}
	sqlite_tx :: proc(app: ^App, w: Well, body: Tx_Body) -> bool {return false}
	sqlite_exec_sql :: proc(app: ^App, sql: string, args: []any) -> bool {return false}
	sqlite_query_sql :: proc(app: ^App, sql: string, args: []any, allocator := context.temp_allocator) -> (Pg_Rows, bool) {return {}, false}
	sqlite_last_id :: proc(app: ^App) -> i64 {return 0}
}
