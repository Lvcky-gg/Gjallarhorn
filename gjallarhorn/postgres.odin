package gjallarhorn

// postgres.odin — Mímir's water: a from-scratch PostgreSQL v3 wire-protocol
// client over core:net, in the same hand-rolled spirit as server.odin's HTTP.
// No libpq. This is the connection layer mimir.odin always deferred — once a
// Pg_Conn is open, `migrate` executes its DDL for real and `exec`/`query` run
// the parameterised statements Mímir builds.
//
// Protocol shape (PostgreSQL Frontend/Backend, version 3.0):
//   - Every backend message is [type:u8][len:i32 incl. len][payload].
//   - The StartupMessage is the one frontend message with no type byte.
//   - Values cross the wire in text format; parameters are sent as text too,
//     so nothing is ever interpolated into SQL (the injection checkpoint holds).
//
// Auth supported: trust (AuthenticationOk), cleartext, and MD5. SASL/SCRAM is
// detected and reported but not implemented — use `md5` or `trust` in pg_hba.

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:crypto/legacy/md5"
import "core:encoding/hex"

Pg_Conn :: struct {
	sock: net.TCP_Socket,
	open: bool,
}

// Rows: the text-format result of a query. NULL columns come back as "".
Pg_Rows :: struct {
	columns: []string,
	rows:    [][]string,
	tag:     string, // command tag, e.g. "INSERT 0 1"
}

// ---------------------------------------------------------------------------
// Public surface (used from mimir.odin / handlers)
// ---------------------------------------------------------------------------

// connect opens the well: dials Postgres and runs the startup/auth handshake,
// storing the live socket on the app. Returns false (and leaves pg.open false)
// on any failure, so callers can fall back to offline behaviour.
connect :: proc(app: ^App) -> bool {
	return pg_open(&app.pg, app.postgres)
}

// disconnect closes the connection if open.
disconnect :: proc(app: ^App) {
	if app.pg.open {
		net.close(app.pg.sock)
		app.pg.open = false
	}
}

// exec runs a statement and discards any rows, returning ok. For INSERT /
// UPDATE / DELETE built by offer / amend / forget.
exec :: proc(w: Well, stmt: Statement) -> bool {
	if w.app == nil || !w.app.pg.open {
		return false
	}
	_, ok := pg_query(&w.app.pg, stmt.sql, stmt.args[:], context.temp_allocator)
	return ok
}

// query runs a statement and returns its rows. For recall(...).sql — and for
// offer(...), whose Postgres form carries RETURNING.
query :: proc(w: Well, stmt: Statement, allocator := context.temp_allocator) -> (Pg_Rows, bool) {
	if w.app == nil || !w.app.pg.open {
		return {}, false
	}
	return pg_query(&w.app.pg, stmt.sql, stmt.args[:], allocator)
}

// ---------------------------------------------------------------------------
// Connection + auth handshake
// ---------------------------------------------------------------------------

pg_open :: proc(conn: ^Pg_Conn, cfg: Postgres_Config) -> bool {
	host := cfg.host
	if host == "" {
		host = "127.0.0.1"
	}
	port := cfg.port
	if port == 0 {
		port = 5432
	}

	ep, rerr := net.resolve_ip4(fmt.tprintf("%s:%d", host, port))
	if rerr != nil {
		fmt.eprintfln("mimir/pg: cannot resolve %s:%d: %v", host, port, rerr)
		return false
	}
	sock, derr := net.dial_tcp(ep)
	if derr != nil {
		fmt.eprintfln("mimir/pg: dial %s:%d failed: %v", host, port, derr)
		return false
	}
	conn.sock = sock

	if !pg_startup(conn, cfg) {
		net.close(sock)
		return false
	}
	conn.open = true
	return true
}

pg_startup :: proc(conn: ^Pg_Conn, cfg: Postgres_Config) -> bool {
	payload := make([dynamic]u8, 0, 64, context.temp_allocator)
	put_u32(&payload, 196608) // protocol version 3.0
	put_str(&payload, "user")
	put_str(&payload, cfg.user)
	if cfg.dbname != "" {
		put_str(&payload, "database")
		put_str(&payload, cfg.dbname)
	}
	append(&payload, 0) // end of parameter list

	// StartupMessage has no type byte: just [len][payload].
	msg := make([dynamic]u8, 0, 80, context.temp_allocator)
	put_u32(&msg, u32(len(payload) + 4))
	append(&msg, ..payload[:])
	if _, err := net.send_tcp(conn.sock, msg[:]); err != nil {
		return false
	}

	return pg_auth(conn, cfg)
}

// pg_auth drives the handshake until ReadyForQuery, answering auth challenges.
pg_auth :: proc(conn: ^Pg_Conn, cfg: Postgres_Config) -> bool {
	for {
		msg, ok := pg_read_msg(conn, context.temp_allocator)
		if !ok {
			return false
		}
		switch msg.type {
		case 'R': // Authentication*
			code := be_u32(msg.payload[0:4])
			switch code {
			case 0: // AuthenticationOk — keep reading until ReadyForQuery
			case 3: // cleartext password
				if !pg_password(conn, cfg.password) {
					return false
				}
			case 5: // MD5 password; salt is the 4 bytes after the code
				hashed := md5_password(cfg.user, cfg.password, msg.payload[4:8])
				if !pg_password(conn, hashed) {
					return false
				}
			case 10: // SASL
				fmt.eprintln("mimir/pg: SASL/SCRAM auth not supported — use md5 or trust in pg_hba.conf")
				return false
			case:
				fmt.eprintfln("mimir/pg: unsupported auth request %d", code)
				return false
			}
		case 'E': // ErrorResponse
			fmt.eprintfln("mimir/pg: %s", pg_error_text(msg.payload))
			return false
		case 'Z': // ReadyForQuery
			return true
		case: // ParameterStatus 'S', BackendKeyData 'K', NoticeResponse 'N' — ignore
		}
	}
}

pg_password :: proc(conn: ^Pg_Conn, password: string) -> bool {
	payload := make([dynamic]u8, 0, 64, context.temp_allocator)
	put_str(&payload, password)
	return pg_send(conn, 'p', payload[:])
}

// ---------------------------------------------------------------------------
// Simple query — used by migrate for parameter-free DDL
// ---------------------------------------------------------------------------

pg_simple :: proc(conn: ^Pg_Conn, sql: string) -> bool {
	payload := make([dynamic]u8, 0, len(sql) + 8, context.temp_allocator)
	put_str(&payload, sql)
	if !pg_send(conn, 'Q', payload[:]) {
		return false
	}

	had_error := false
	for {
		msg, ok := pg_read_msg(conn, context.temp_allocator)
		if !ok {
			return false
		}
		switch msg.type {
		case 'E':
			fmt.eprintfln("mimir/pg: %s", pg_error_text(msg.payload))
			had_error = true
		case 'Z': // ReadyForQuery terminates the exchange
			return !had_error
		case: // RowDescription/DataRow/CommandComplete — ignored for DDL
		}
	}
}

// ---------------------------------------------------------------------------
// Extended query — Parse/Bind/Describe/Execute/Sync, with bound parameters
// ---------------------------------------------------------------------------

pg_query :: proc(conn: ^Pg_Conn, sql: string, args: []any, allocator := context.temp_allocator) -> (out: Pg_Rows, ok: bool) {
	// Parse (unnamed statement, let the server infer parameter types).
	parse := make([dynamic]u8, 0, len(sql) + 16, context.temp_allocator)
	put_str(&parse, "")
	put_str(&parse, sql)
	put_u16(&parse, 0)
	pg_send(conn, 'P', parse[:]) or_return

	// Bind (unnamed portal): all params and results in text format.
	bind := make([dynamic]u8, 0, 64, context.temp_allocator)
	put_str(&bind, "") // portal
	put_str(&bind, "") // statement
	put_u16(&bind, 0)  // 0 param format codes => all text
	put_u16(&bind, u16(len(args)))
	for a in args {
		if a == nil {
			put_u32(&bind, 0xFFFF_FFFF) // -1 length => NULL
			continue
		}
		s := fmt.tprintf("%v", a)
		put_u32(&bind, u32(len(s)))
		append(&bind, ..transmute([]u8)s)
	}
	put_u16(&bind, 0) // 0 result format codes => all text
	pg_send(conn, 'B', bind[:]) or_return

	// Describe the portal so we receive a RowDescription, then Execute + Sync.
	desc := make([dynamic]u8, 0, 8, context.temp_allocator)
	append(&desc, 'P')
	put_str(&desc, "")
	pg_send(conn, 'D', desc[:]) or_return

	exe := make([dynamic]u8, 0, 8, context.temp_allocator)
	put_str(&exe, "")  // portal
	put_u32(&exe, 0)   // unlimited rows
	pg_send(conn, 'E', exe[:]) or_return

	pg_send(conn, 'S', nil) or_return // Sync

	rows := make([dynamic][]string, allocator)
	had_error := false
	for {
		msg := pg_read_msg(conn, context.temp_allocator) or_return
		switch msg.type {
		case 'T': // RowDescription
			out.columns = parse_row_description(msg.payload, allocator)
		case 'D': // DataRow
			append(&rows, parse_data_row(msg.payload, allocator))
		case 'C': // CommandComplete — payload is the command tag (cstring)
			out.tag = strings.clone(cstring_of(msg.payload), allocator)
		case 'E': // ErrorResponse
			fmt.eprintfln("mimir/pg: %s", pg_error_text(msg.payload))
			had_error = true
		case 'Z': // ReadyForQuery
			out.rows = rows[:]
			return out, !had_error
		case: // ParseComplete '1', BindComplete '2', NoData 'n' — ignore
		}
	}
}

parse_row_description :: proc(payload: []u8, allocator: runtime.Allocator) -> []string {
	r := Reader{buf = payload}
	n := int(r_u16(&r))
	cols := make([]string, n, allocator)
	for i in 0 ..< n {
		cols[i] = strings.clone(r_cstr(&r), allocator)
		r.off += 18 // tableOID(4)+colAttr(2)+typeOID(4)+typLen(2)+typMod(4)+format(2)
	}
	return cols
}

parse_data_row :: proc(payload: []u8, allocator: runtime.Allocator) -> []string {
	r := Reader{buf = payload}
	n := int(r_u16(&r))
	row := make([]string, n, allocator)
	for i in 0 ..< n {
		length := i32(r_u32(&r))
		if length < 0 {
			row[i] = "" // NULL
			continue
		}
		row[i] = strings.clone(string(r_bytes(&r, int(length))), allocator)
	}
	return row
}

// ---------------------------------------------------------------------------
// Framing + low-level I/O
// ---------------------------------------------------------------------------

Pg_Msg :: struct {
	type:    u8,
	payload: []u8,
}

// pg_send frames a frontend message: [type][len incl. len][payload].
pg_send :: proc(conn: ^Pg_Conn, type: u8, payload: []u8) -> bool {
	msg := make([dynamic]u8, 0, len(payload) + 5, context.temp_allocator)
	append(&msg, type)
	put_u32(&msg, u32(len(payload) + 4))
	append(&msg, ..payload)
	_, err := net.send_tcp(conn.sock, msg[:])
	return err == nil
}

// pg_read_msg reads one full backend message, blocking until it arrives.
pg_read_msg :: proc(conn: ^Pg_Conn, allocator := context.temp_allocator) -> (Pg_Msg, bool) {
	head: [5]u8
	if !pg_read_full(conn, head[:]) {
		return {}, false
	}
	plen := int(be_u32(head[1:5])) - 4
	if plen < 0 {
		return {}, false
	}
	payload := make([]u8, plen, allocator)
	if plen > 0 && !pg_read_full(conn, payload) {
		return {}, false
	}
	return Pg_Msg{type = head[0], payload = payload}, true
}

// pg_read_full loops recv until dst is filled or the socket fails.
pg_read_full :: proc(conn: ^Pg_Conn, dst: []u8) -> bool {
	off := 0
	for off < len(dst) {
		n, err := net.recv_tcp(conn.sock, dst[off:])
		if err != nil || n == 0 {
			return false
		}
		off += n
	}
	return true
}

// pg_error_text flattens an ErrorResponse into "SEVERITY: message (CODE)".
pg_error_text :: proc(payload: []u8) -> string {
	r := Reader{buf = payload}
	severity, message, code := "", "", ""
	for r.off < len(payload) {
		field := payload[r.off]
		r.off += 1
		if field == 0 {
			break
		}
		value := r_cstr(&r)
		switch field {
		case 'S': severity = value
		case 'M': message = value
		case 'C': code = value
		}
	}
	return fmt.tprintf("%s: %s (%s)", severity, message, code)
}

// ---------------------------------------------------------------------------
// Byte helpers — big-endian writes, a cursor reader, MD5 auth
// ---------------------------------------------------------------------------

put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}
put_u16 :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v >> 8), u8(v))
}
// put_str writes a null-terminated string (the protocol's String type).
put_str :: proc(b: ^[dynamic]u8, s: string) {
	append(b, ..transmute([]u8)s)
	append(b, 0)
}

be_u32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}
be_u16 :: proc(b: []u8) -> u16 {
	return u16(b[0]) << 8 | u16(b[1])
}

cstring_of :: proc(b: []u8) -> string {
	for c, i in b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

// Reader: a forward cursor over a message payload.
Reader :: struct {
	buf: []u8,
	off: int,
}
r_u16 :: proc(r: ^Reader) -> u16 {
	v := be_u16(r.buf[r.off:])
	r.off += 2
	return v
}
r_u32 :: proc(r: ^Reader) -> u32 {
	v := be_u32(r.buf[r.off:])
	r.off += 4
	return v
}
r_cstr :: proc(r: ^Reader) -> string {
	start := r.off
	for r.off < len(r.buf) && r.buf[r.off] != 0 {
		r.off += 1
	}
	s := string(r.buf[start:r.off])
	r.off += 1 // skip the null terminator
	return s
}
r_bytes :: proc(r: ^Reader, n: int) -> []u8 {
	b := r.buf[r.off:r.off + n]
	r.off += n
	return b
}

// md5_password computes the PostgreSQL MD5 auth token:
//   "md5" + hex( md5( hex(md5(password + user)) + salt ) )
md5_password :: proc(user, password: string, salt: []u8) -> string {
	inner := md5_hex(transmute([]u8)strings.concatenate({password, user}, context.temp_allocator))

	outer := make([dynamic]u8, 0, len(inner) + 4, context.temp_allocator)
	append(&outer, ..transmute([]u8)inner)
	append(&outer, ..salt)

	return strings.concatenate({"md5", md5_hex(outer[:])}, context.temp_allocator)
}

md5_hex :: proc(data: []u8) -> string {
	sum: [md5.DIGEST_SIZE]u8
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, data)
	md5.final(&ctx, sum[:])
	encoded, _ := hex.encode(sum[:], context.temp_allocator)
	return string(encoded)
}
