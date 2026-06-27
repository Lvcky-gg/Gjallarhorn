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
// Auth supported: trust (AuthenticationOk), cleartext, MD5, and SCRAM-SHA-256
// (RFC 5802/7677) — the default for stock modern Postgres. No pg_hba changes
// needed to connect to a default-configured server.

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "core:crypto"
import "core:crypto/hmac"
import "core:crypto/pbkdf2"
import "core:crypto/sha2"
import "core:crypto/legacy/md5"
import "core:encoding/base64"
import "core:encoding/hex"

Pg_Conn :: struct {
	sock: net.TCP_Socket,
	ssl:  rawptr, // OpenSSL SSL* once TLS is active; nil otherwise (GH-031)
	tls:  bool,   // when true, pg_send/pg_read_full route through the TLS session
	open: bool,
	idx:  int, // slot within its Pg_Pool (0 when standalone)
}

// Pg_Pool is a small fixed-size set of connections with checkout/return,
// guarded so concurrent handlers (GH-010) never share a connection. A
// semaphore counts free connections; a worker that finds none blocks until one
// is returned. The mutex protects the free-list.
Pg_Pool :: struct {
	conns:     []Pg_Conn,
	available: [dynamic]int, // indices of free connections
	mutex:     sync.Mutex,
	sem:       sync.Sema,
	size:      int,
	open:      bool,
}

Pg_Rows :: struct {
	columns: []string,
	rows:    [][]string,
	tag:     string,   // command tag, e.g. "INSERT 0 1"
	err:     Pg_Error, // set (err.code != "") when the query failed; see GH-032
}

// Pg_Error is a Postgres ErrorResponse, surfaced so handlers can see why a
// query failed rather than only a bool. `code` is the SQLSTATE (e.g. "23505").
Pg_Error :: struct {
	severity: string,
	message:  string,
	code:     string,
}

// failed reports whether rows carries a server error (vs. an empty/clean read).
failed :: proc(rows: Pg_Rows) -> bool {
	return rows.err.code != ""
}

connect :: proc(app: ^App) -> bool {
	return pool_open(&app.pool, app.postgres, app.pool_size)
}

disconnect :: proc(app: ^App) {
	pool_close(&app.pool)
}

exec :: proc(w: Well, stmt: Statement) -> bool {
	conn, release, ok := well_conn(w)
	if !ok {
		return false
	}
	_, qok := pg_query(conn, stmt.sql, stmt.args[:], context.temp_allocator)
	if release {
		pool_release(&w.app.pool, conn)
	}
	return qok
}

query_well :: proc(w: Well, stmt: Statement, allocator := context.temp_allocator) -> (Pg_Rows, bool) {
	conn, release, ok := well_conn(w)
	if !ok {
		return {}, false
	}
	out, qok := pg_query(conn, stmt.sql, stmt.args[:], allocator)
	if release {
		pool_release(&w.app.pool, conn)
	}
	return out, qok
}

// well_conn yields the connection a Well should use. A transaction pins one
// (w.conn set) and must not be released per statement; otherwise we check one
// out of the pool and tell the caller to return it (release=true).
well_conn :: proc(w: Well) -> (conn: ^Pg_Conn, release: bool, ok: bool) {
	if w.app == nil || !w.app.pool.open {
		return nil, false, false
	}
	if w.conn != nil {
		return w.conn, false, true
	}
	c, acquired := pool_acquire(&w.app.pool)
	if !acquired {
		return nil, false, false
	}
	return c, true, true
}

// ---------------------------------------------------------------------------
// Connection pool (GH-024)
// ---------------------------------------------------------------------------

// pool_open dials `size` connections up front (min 1). If any fails, it closes
// the ones already opened and reports failure — an all-or-nothing pool.
pool_open :: proc(pool: ^Pg_Pool, cfg: Postgres_Config, size: int) -> bool {
	n := size
	if n <= 0 {
		n = 1
	}
	pool.conns = make([]Pg_Conn, n)
	pool.available = make([dynamic]int, 0, n)
	for i in 0 ..< n {
		if !pg_open(&pool.conns[i], cfg) {
			for j in 0 ..< i {
				pg_sock_close(&pool.conns[j])
			}
			delete_slice(pool.conns)
			delete_dynamic_array(pool.available)
			pool^ = {}
			return false
		}
		pool.conns[i].idx = i
		append(&pool.available, i)
	}
	pool.size = n
	sync.sema_post(&pool.sem, n)
	pool.open = true
	return true
}

pool_close :: proc(pool: ^Pg_Pool) {
	if !pool.open {
		return
	}
	for i in 0 ..< len(pool.conns) {
		if pool.conns[i].open {
			pg_sock_close(&pool.conns[i])
			pool.conns[i].open = false
		}
	}
	delete_slice(pool.conns)
	delete_dynamic_array(pool.available)
	pool.open = false
}

// pool_acquire blocks until a connection is free, then hands it out.
pool_acquire :: proc(pool: ^Pg_Pool) -> (^Pg_Conn, bool) {
	if !pool.open {
		return nil, false
	}
	sync.sema_wait(&pool.sem)
	sync.mutex_lock(&pool.mutex)
	idx := pop(&pool.available)
	sync.mutex_unlock(&pool.mutex)
	return &pool.conns[idx], true
}

// pool_release returns a connection to the free-list and wakes one waiter.
pool_release :: proc(pool: ^Pg_Pool, conn: ^Pg_Conn) {
	sync.mutex_lock(&pool.mutex)
	append(&pool.available, conn.idx)
	sync.mutex_unlock(&pool.mutex)
	sync.sema_post(&pool.sem)
}

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

	if !pg_negotiate_tls(conn, cfg) {
		net.close(sock)
		return false
	}

	if !pg_startup(conn, cfg) {
		pg_sock_close(conn)
		return false
	}
	conn.open = true
	return true
}

// pg_negotiate_tls runs the pre-startup SSLRequest exchange (GH-031). For
// sslmode=disable it is a no-op. Otherwise it sends the 8-byte SSLRequest in
// cleartext, reads the single-byte reply ('S' = TLS available, 'N' = not), and
// upgrades the socket to TLS when offered. require/verify-full fail if TLS can't
// be had; prefer falls back to cleartext on 'N'. Any non-disable mode needs a
// TLS build (-define:GJ_TLS=true); without it we refuse rather than silently
// sending the password in the clear.
pg_negotiate_tls :: proc(conn: ^Pg_Conn, cfg: Postgres_Config) -> bool {
	if cfg.sslmode == .Disable {
		return true
	}
	when !GJ_TLS {
		fmt.eprintfln(
			"mimir/pg: sslmode=%v requires a TLS build — rebuild with -define:GJ_TLS=true",
			cfg.sslmode,
		)
		return false
	}

	// SSLRequest: [len=8:i32][80877103:i32], sent before any startup message.
	req := [8]u8{0, 0, 0, 8, 0x04, 0xd2, 0x16, 0x2f} // 8, then 80877103
	if _, err := net.send_tcp(conn.sock, req[:]); err != nil {
		return false
	}
	reply: [1]u8
	n, rerr := net.recv_tcp(conn.sock, reply[:])
	if rerr != nil || n != 1 {
		return false
	}

	switch reply[0] {
	case 'S':
		host := cfg.host if cfg.host != "" else "127.0.0.1"
		return pg_tls_handshake(conn, host, cfg.sslmode == .Verify_Full)
	case 'N':
		if cfg.sslmode == .Prefer {
			return true // server has no TLS; proceed in cleartext
		}
		fmt.eprintln("mimir/pg: server declined TLS (SSLRequest 'N') but sslmode requires it")
		return false
	case:
		fmt.eprintfln("mimir/pg: unexpected SSLRequest reply 0x%02x", reply[0])
		return false
	}
}

// pg_sock_close tears down a connection's TLS session (if any) and its socket.
pg_sock_close :: proc(conn: ^Pg_Conn) {
	if conn.tls {
		pg_tls_close(conn)
	}
	net.close(conn.sock)
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

	msg := make([dynamic]u8, 0, 80, context.temp_allocator)
	put_u32(&msg, u32(len(payload) + 4))
	append(&msg, ..payload[:])
	if conn.tls {
		if !pg_tls_send(conn, msg[:]) {
			return false
		}
	} else if _, err := net.send_tcp(conn.sock, msg[:]); err != nil {
		return false
	}

	return pg_auth(conn, cfg)
}

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
			case 10: // SASL — the mechanism list follows the code
				if !pg_scram(conn, cfg, msg.payload[4:]) {
					return false
				}
			case:
				fmt.eprintfln("mimir/pg: unsupported auth request %d", code)
				return false
			}
		case 'E': // ErrorResponse
			fmt.eprintfln("mimir/pg: %s", pg_error_text(parse_pg_error(msg.payload)))
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
// SCRAM-SHA-256 (GH-030) — RFC 5802 / RFC 7677, no channel binding.
// ---------------------------------------------------------------------------
//
// Four messages: we send client-first, the server replies server-first (a
// nonce, salt and iteration count), we send client-final (a proof derived from
// the salted password), and the server replies server-final (a signature we
// verify). Postgres frames these as SASLInitialResponse/SASLResponse ('p') and
// AuthenticationSASLContinue/Final ('R', codes 11/12).
pg_scram :: proc(conn: ^Pg_Conn, cfg: Postgres_Config, mechanisms: []u8) -> bool {
	if !scram_offers(mechanisms, "SCRAM-SHA-256") {
		fmt.eprintln("mimir/pg: server did not offer SCRAM-SHA-256")
		return false
	}

	// client-first. gs2 header "n,," = no channel binding; the username is
	// empty because Postgres uses the startup-message user.
	nonce_raw: [18]u8
	crypto.rand_bytes(nonce_raw[:])
	client_nonce, _ := base64.encode(nonce_raw[:], allocator = context.temp_allocator)
	client_first_bare := fmt.tprintf("n=,r=%s", client_nonce)
	client_first := fmt.tprintf("n,,%s", client_first_bare)

	// SASLInitialResponse: mechanism name, then a length-prefixed message.
	init := make([dynamic]u8, 0, 64, context.temp_allocator)
	put_str(&init, "SCRAM-SHA-256")
	put_u32(&init, u32(len(client_first)))
	append(&init, ..transmute([]u8)client_first)
	if !pg_send(conn, 'p', init[:]) {
		return false
	}

	// server-first (AuthenticationSASLContinue, code 11).
	cont, ok := pg_read_msg(conn, context.temp_allocator)
	if !ok || cont.type != 'R' || be_u32(cont.payload[0:4]) != 11 {
		fmt.eprintln("mimir/pg: expected SASLContinue")
		return false
	}
	server_first := string(cont.payload[4:])
	server_nonce, salt_b64, iter_s, parsed := scram_server_first(server_first)
	if !parsed || !strings.has_prefix(server_nonce, client_nonce) {
		fmt.eprintln("mimir/pg: malformed server-first or nonce mismatch")
		return false
	}
	salt, _ := base64.decode(salt_b64, allocator = context.temp_allocator)
	iterations, _ := strconv.parse_int(iter_s)

	// SaltedPassword = PBKDF2-HMAC-SHA256(password, salt, i)
	salted: [32]u8
	pbkdf2.derive(.SHA256, transmute([]u8)cfg.password, salt, u32(iterations), salted[:])

	// ClientKey / StoredKey, and the AuthMessage all three signatures share.
	client_key: [32]u8
	hmac.sum(.SHA256, client_key[:], transmute([]u8)string("Client Key"), salted[:])
	stored_key: [32]u8
	sha256(client_key[:], stored_key[:])

	client_final_bare := fmt.tprintf("c=biws,r=%s", server_nonce) // biws = base64("n,,")
	auth_message := fmt.tprintf("%s,%s,%s", client_first_bare, server_first, client_final_bare)

	// ClientProof = ClientKey XOR HMAC(StoredKey, AuthMessage)
	client_sig: [32]u8
	hmac.sum(.SHA256, client_sig[:], transmute([]u8)auth_message, stored_key[:])
	proof: [32]u8
	for i in 0 ..< 32 {
		proof[i] = client_key[i] ~ client_sig[i]
	}
	proof_b64, _ := base64.encode(proof[:], allocator = context.temp_allocator)

	client_final := fmt.tprintf("%s,p=%s", client_final_bare, proof_b64)
	if !pg_send(conn, 'p', transmute([]u8)client_final) {
		return false
	}

	// server-final (AuthenticationSASLFinal, code 12): verify ServerSignature.
	fin, fok := pg_read_msg(conn, context.temp_allocator)
	if !fok || fin.type != 'R' || be_u32(fin.payload[0:4]) != 12 {
		fmt.eprintln("mimir/pg: expected SASLFinal (bad password?)")
		return false
	}
	server_final := string(fin.payload[4:])
	if !strings.has_prefix(server_final, "v=") {
		fmt.eprintln("mimir/pg: malformed server-final")
		return false
	}

	server_key: [32]u8
	hmac.sum(.SHA256, server_key[:], transmute([]u8)string("Server Key"), salted[:])
	expected: [32]u8
	hmac.sum(.SHA256, expected[:], transmute([]u8)auth_message, server_key[:])
	expected_b64, _ := base64.encode(expected[:], allocator = context.temp_allocator)
	if server_final[2:] != expected_b64 {
		fmt.eprintln("mimir/pg: SCRAM server signature verification failed")
		return false
	}
	return true
}

// scram_offers reports whether a SASL mechanism list (null-terminated strings,
// terminated by an empty string) includes the named mechanism.
scram_offers :: proc(list: []u8, want: string) -> bool {
	r := Reader{buf = list}
	for r.off < len(list) {
		mech := r_cstr(&r)
		if mech == "" {
			break
		}
		if mech == want {
			return true
		}
	}
	return false
}

// scram_server_first pulls r=, s=, i= out of the server-first message.
scram_server_first :: proc(s: string) -> (nonce, salt, iter: string, ok: bool) {
	for tok in strings.split(s, ",", context.temp_allocator) {
		if len(tok) < 2 {
			continue
		}
		switch tok[:2] {
		case "r=": nonce = tok[2:]
		case "s=": salt = tok[2:]
		case "i=": iter = tok[2:]
		}
	}
	ok = nonce != "" && salt != "" && iter != ""
	return
}

sha256 :: proc(data, dst: []u8) {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, dst)
}

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
			fmt.eprintfln("mimir/pg: %s", pg_error_text(parse_pg_error(msg.payload)))
			had_error = true
		case 'Z': // ReadyForQuery terminates the exchange
			return !had_error
		case: // RowDescription/DataRow/CommandComplete — ignored for DDL
		}
	}
}

pg_query :: proc(conn: ^Pg_Conn, sql: string, args: []any, allocator := context.temp_allocator) -> (out: Pg_Rows, ok: bool) {
	// Encode every bind arg to Postgres text format up front, before any bytes
	// hit the wire — so an unsupported type fails loudly here, leaving the
	// connection clean rather than half-sent and desynced.
	encoded := make([]string, len(args), context.temp_allocator)
	is_null := make([]bool, len(args), context.temp_allocator)
	for a, i in args {
		if a == nil {
			is_null[i] = true
			continue
		}
		text, enc_ok := encode_arg(a, context.temp_allocator)
		if !enc_ok {
			fmt.eprintfln("mimir/pg: cannot encode bind arg $%d of type %v", i + 1, a.id)
			return {}, false
		}
		encoded[i] = text
	}

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
	for i in 0 ..< len(args) {
		if is_null[i] {
			put_u32(&bind, 0xFFFF_FFFF) // -1 length => NULL
			continue
		}
		s := encoded[i]
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
		case 'E': // ErrorResponse — keep it structured for the caller
			out.err = parse_pg_error(msg.payload, allocator)
			fmt.eprintfln("mimir/pg: %s", pg_error_text(out.err))
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
// Bind-argument encoding (GH-021)
// ---------------------------------------------------------------------------
//
// Every parameter crosses the wire in text format; the server coerces the text
// to the target column's type. The supported Odin -> Postgres mapping:
//
//   int, i8..i64, uint, u8..u64   decimal literal        int2/int4/int8, numeric
//   f32, f64                      %v (shortest form)     real/double, numeric
//   bool                          't' / 'f'              boolean
//   string, cstring               verbatim               text/varchar/char/...
//   []u8                          '\xDEADBEEF' hex form  bytea
//   time.Time                     'YYYY-MM-DD HH:MM:SS'  timestamp / date
//
// Any other type returns ok=false: pg_query then refuses the statement rather
// than shipping a `%v` rendering the server can't parse (the old behaviour).
encode_arg :: proc(a: any, allocator := context.temp_allocator) -> (text: string, ok: bool) {
	switch v in a {
	case int:     return fmt.aprintf("%d", v, allocator = allocator), true
	case i8:      return fmt.aprintf("%d", v, allocator = allocator), true
	case i16:     return fmt.aprintf("%d", v, allocator = allocator), true
	case i32:     return fmt.aprintf("%d", v, allocator = allocator), true
	case i64:     return fmt.aprintf("%d", v, allocator = allocator), true
	case uint:    return fmt.aprintf("%d", v, allocator = allocator), true
	case u8:      return fmt.aprintf("%d", v, allocator = allocator), true
	case u16:     return fmt.aprintf("%d", v, allocator = allocator), true
	case u32:     return fmt.aprintf("%d", v, allocator = allocator), true
	case u64:     return fmt.aprintf("%d", v, allocator = allocator), true
	case f32:     return fmt.aprintf("%v", v, allocator = allocator), true
	case f64:     return fmt.aprintf("%v", v, allocator = allocator), true
	case bool:    return v ? "t" : "f", true
	case string:  return v, true
	case cstring: return strings.clone(string(v), allocator), true
	case []u8:    return bytea_text(v, allocator), true
	case time.Time:
		y, mo, d := time.date(v)
		h, mi, s := time.clock_from_time(v)
		return fmt.aprintf(
			"%04d-%02d-%02d %02d:%02d:%02d",
			y, int(mo), d, h, mi, s,
			allocator = allocator,
		), true
	}
	return "", false
}

// bytea_text renders bytes as Postgres's hex bytea input: \x followed by hex.
bytea_text :: proc(b: []u8, allocator := context.temp_allocator) -> string {
	encoded, _ := hex.encode(b, allocator)
	return strings.concatenate({"\\x", string(encoded)}, allocator)
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
	if conn.tls {
		return pg_tls_send(conn, msg[:])
	}
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
		n: int
		if conn.tls {
			ok: bool
			n, ok = pg_tls_recv(conn, dst[off:])
			if !ok {
				return false
			}
		} else {
			err: net.Network_Error
			n, err = net.recv_tcp(conn.sock, dst[off:])
			if err != nil {
				return false
			}
		}
		if n == 0 {
			return false
		}
		off += n
	}
	return true
}

// parse_pg_error reads an ErrorResponse payload into a Pg_Error. Fields are
// `[field-byte][cstring]` pairs terminated by a zero byte; we keep severity (S),
// message (M) and the SQLSTATE code (C). Strings are cloned so the error
// outlives the (often temporary) payload buffer.
parse_pg_error :: proc(payload: []u8, allocator := context.temp_allocator) -> Pg_Error {
	r := Reader{buf = payload}
	e: Pg_Error
	for r.off < len(payload) {
		field := payload[r.off]
		r.off += 1
		if field == 0 {
			break
		}
		value := r_cstr(&r)
		switch field {
		case 'S': e.severity = strings.clone(value, allocator)
		case 'M': e.message = strings.clone(value, allocator)
		case 'C': e.code = strings.clone(value, allocator)
		}
	}
	return e
}

// pg_error_text flattens a Pg_Error into "SEVERITY: message (CODE)" for logs.
pg_error_text :: proc(e: Pg_Error) -> string {
	return fmt.tprintf("%s: %s (%s)", e.severity, e.message, e.code)
}

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
