# Gjallarhorn — Development Backlog

Tickets derived from a full read of the codebase (~2,300 LOC framework). Each
ticket names the file(s) and procs it touches so it can be picked up cold.

**Priority key**
- **P0** — blocks building any real app; the framework is a demo until these land
- **P1** — needed before anything production-facing
- **P2** — maturity / polish / breadth

**Effort key:** S (hours) · M (a day) · L (multi-day)

---

## Epic 1 — HTTP Core (request side)

This is the highest-leverage epic. Until GH-001 and GH-002 land, the server can
only read a request line, and apps have to smuggle data through path params.

### GH-001 · Parse request headers · **P0** · M
**Component:** `server.odin`, `bifrost.odin`
**Problem:** `handle_connection` reads only the request line; headers are dropped.
The `headers` map on `Bifrost` is response-only, so handlers can't read
`Content-Type`, `Authorization`, `Cookie`, `Host`, etc.
**Done when:**
- Request headers are parsed into a `req_headers: map[string]string` on `Bifrost` (case-insensitive lookup).
- A `header(b, key) -> (string, bool)` accessor exists.
- Malformed header lines return `400` without crashing the loop.
- A test covers multi-header parsing and a missing-header lookup.
**DONE**

### GH-002 · Read full request body with Content-Length loop · **P0** · M
**Component:** `server.odin`
**Problem:** A single 8KB `net.recv_tcp` into a fixed `[8192]u8` buffer. Bodies
larger than 8KB, or any request split across TCP segments, are truncated.
**Depends on:** GH-001 (needs parsed headers to find `Content-Length`).
**Done when:**
- After the header block, the body is read in a loop until `Content-Length` bytes are received.
- `MAX_REQUEST` is replaced with a configurable max body size that returns `413` when exceeded.
- The raw body is exposed as `b.body: []u8` / `b.body_text: string`.
- Test: a >8KB POST body round-trips intact.
**DONE**

### GH-003 · Body decoders: JSON + urlencoded form · **P0** · M
**Component:** new `body.odin`, `bifrost.odin`
**Problem:** No way to read a typed payload. The sample app puts data in the
URL (`POST /sample/:name`) purely to work around this.
**Depends on:** GH-002.
**Done when:**
- `bind_json(b, ^T) -> bool` unmarshals a JSON body into a struct via `core:encoding/json`.
- `form(b) -> map[string]string` parses `application/x-www-form-urlencoded`.
- Sample `create_handler`/`update_handler` are rewritten to take the name from the body, not the path.
- Tests for both decoders, including malformed input → `400`.
**DONE**

### GH-004 · Parse and expose query-string params · **P1** · S
**Component:** `server.odin`, `bifrost.odin`
**Problem:** The query string is stripped and discarded in `handle_connection`.
**Done when:**
- `?k=v&...` is parsed into `b.query: map[string]string` (URL-decoded).
- `query(b, key) -> (string, bool)` accessor + test.
**DONE**

### GH-005 · Percent-decode path and param values · **P1** · S
**Component:** `router.odin`
**Problem:** `match_path` captures raw path segments; `%20` etc. are not decoded.
**Done when:** captured params and the routed path are percent-decoded before handlers see them; test with an encoded segment.
**DONE**

### GH-006 · HTTP keep-alive / connection reuse · **P1** · M
**Component:** `server.odin`, `response.odin`
**Problem:** Every response sends `Connection: close`; one request per socket.
**Depends on:** GH-002 (need framed reads to know where one request ends).
**Done when:** honors `Connection: keep-alive` on HTTP/1.1, loops multiple requests per socket, with an idle timeout. Falls back to close on `Connection: close`.
**DONE**

---

## Epic 2 — Concurrency & Server

### GH-010 · Concurrent connection handling · **P1** · L
**Component:** `server.odin`
**Problem:** `handle_connection` runs inline in the accept loop — strictly one
connection at a time. A single slow client blocks the entire server.
**Done when:**
- Each accepted connection is handled off the accept thread (thread pool via `core:thread`, or one-goroutine-per-conn equivalent).
- The accept loop never blocks on request handling.
- `free_all(context.temp_allocator)` is made per-handler-safe (it currently assumes single-threaded temp-allocator reuse — this WILL break under threads and must be addressed as part of this ticket).
- Load test: N concurrent slow clients don't stall fast ones.
**DONE**

### GH-011 · Panic recovery per request · **P1** · S
**Component:** `server.odin`, `middleware.odin`
**Problem:** A crashing handler takes down the whole process; no isolation.
**Depends on:** GH-010 (recovery boundary lives at the per-connection seam).
**Done when:** a handler panic is caught, logged, and returns `500` without killing the server.
**DONE**

### GH-012 · Bind to a configurable interface (not just loopback) · **P1** · S
**Component:** `server.odin`, `app.odin`
**Problem:** `net.IP4_Loopback` is hardcoded; `Config.root` is set but never used.
**Done when:** host/bind address is configurable (default loopback); `Config.root` is either wired up or removed.
**DONE**

---

## Epic 3 — Mímir ORM (read path & lifecycle)

### GH-020 · Hydrate query results into structs · **P0** · L
**Component:** `mimir.odin`, `postgres.odin`
**Problem:** `recall`/`query` return `Pg_Rows` as `[][]string`. There is no scan
from result rows back into typed structs — the ORM writes but can't read. Callers
parse columns by hand (`create_handler` parses `RETURNING id` from a string).
**Depends on:** column metadata from `columns_of` (exists).
**Done when:**
- `scan(rows, ^T) -> []T` (or `scan_one`) maps result columns to struct fields by column name, converting text → field type (int/f64/bool/string at minimum).
- NULL handling defined (zero value or optional).
- `get_handler` reads a real row from the DB instead of returning a hardcoded `Sample`.
- Tests against the docker Postgres covering scan of each supported type.
**DONE**

### GH-021 · Typed parameter encoding for bind args · **P1** · M
**Component:** `postgres.odin` (`pg_query` bind loop)
**Problem:** Every bind arg is stringified with `fmt.tprintf("%v", a)`. Fine for
int/string/bool, but breaks for timestamps, numeric/decimal, bytea, and any
type whose `%v` form Postgres won't accept.
**Depends on:** GH-020 (shared type-mapping table).
**Done when:** a documented arg-encoding table covers the supported Odin types; dates/timestamps handled; an unsupported type fails loudly rather than silently sending garbage.
**DONE**

### GH-022 · Transactions (BEGIN/COMMIT/ROLLBACK) · **P1** · M
**Component:** new `mimir.odin` procs over `postgres.odin`
**Problem:** No transaction support; multi-statement writes can't be atomic.
**Done when:** `tx(w, proc)` helper or explicit `begin`/`commit`/`forget`-style verbs; rollback on error; test that a failed second statement rolls back the first.
**DONE**

### GH-023 · Schema migration beyond CREATE TABLE IF NOT EXISTS · **P1** · L
**Component:** `mimir.odin` (`migrate`, `carve`)
**Problem:** `migrate` only issues `CREATE TABLE IF NOT EXISTS`. Adding a column
to a model does nothing to an existing table — no ALTER, no diffing, no versioning.
**Done when:**
- Detects existing columns (query `information_schema`) and emits `ALTER TABLE ADD COLUMN` for new fields.
- A migration version/log table or an explicit ordered-migration mechanism.
- Test: add a field to a model → column appears on next `run()`.
**DONE**

### GH-024 · Connection pooling · **P1** · M
**Component:** `postgres.odin`, `app.odin`
**Problem:** A single `Pg_Conn` on the `App`. Consistent under today's
single-threaded server, but incompatible with GH-010.
**Depends on:** GH-010.
**Done when:** a small fixed-size pool with checkout/return; safe under concurrent handlers; configurable size.

### GH-025 · Relationships / foreign keys · **P2** · L
**Component:** `mimir.odin`
**Problem:** No FK DDL, joins, associations, or eager loading.
**Done when:** at minimum a `db:"...,fk:other.id"` tag emits a FK constraint; a documented pattern (or helper) for join queries. Full association loading can be a follow-up.

---

## Epic 4 — Postgres Driver hardening

### GH-030 · SCRAM-SHA-256 authentication · **P1** · L
**Component:** `postgres.odin` (`pg_auth`, case `10`)
**Problem:** SASL/SCRAM is detected and refused. Stock modern Postgres defaults
to `scram-sha-256`, and managed cloud DBs force it — so the driver can't connect
to a realistic database without downgrading `pg_hba` to trust/md5.
**Done when:**
- SCRAM-SHA-256 client flow implemented (client-first, server-first, client-final, server-final verification) using `core:crypto`.
- Connects against a default-configured Postgres 16 with no `pg_hba` changes.
- docker-compose comment about trust-auth workaround updated/removed.

### GH-031 · TLS for the Postgres connection · **P1** · L
**Component:** `postgres.odin` (`pg_open` / startup)
**Problem:** Connection is cleartext; under cleartext-auth the password crosses
the wire in the open. Managed Postgres typically requires TLS.
**Depends on:** a TLS story for `core:net` (may need `core:crypto/tls` or an external approach — spike first).
**Done when:** `sslmode`-style option; SSLRequest handshake before startup; verified connection to a TLS-required server.

### GH-032 · Driver error surfacing to handlers · **P2** · S
**Component:** `postgres.odin`, `mimir.odin`
**Problem:** Errors are `eprintfln`'d and flattened to a bool; handlers can't see
*why* a query failed (only `503 database unavailable`).
**Done when:** errors return a structured `Pg_Error{severity, message, code}` that handlers can inspect; the SQLSTATE code is preserved.

---

## Epic 5 — Loom Templating

### GH-040 · Template inheritance: `{% extends %}` / `{% block %}` · **P2** · L
**Component:** `loom.odin`
**Problem:** No inheritance — every page repeats its full HTML shell. Flagged in
the file's own phase note.
**Done when:** child templates extend a base and override named blocks; resolution reads the base from the same mount dir; tests for override + default-block fallthrough.

### GH-041 · `{% include %}` · **P2** · M
**Component:** `loom.odin`
**Problem:** No partials/includes.
**Done when:** `{% include "partial.html" %}` renders another template with the current context; path-traversal-clamped like the mounts (`safe_target`).

### GH-042 · Compiled-node cache · **P2** · M
**Component:** `loom.odin` (`weave`)
**Problem:** Templates are lexed/parsed on every render. The file calls this out
as the optimization seam.
**Done when:** parsed node trees are cached keyed by template path + mtime; cache invalidates on file change; a benchmark shows the win.

### GH-043 · Render typed structs directly into templates · **P2** · M
**Component:** `loom.odin` (`Value`, `warp`), bridge to `mimir.odin`
**Problem:** `Value` is a closed union; you must hand-build `Warp` maps. The
typed model layer (structs) and the template layer (Value unions) don't connect,
so ORM rows can't flow straight into a template.
**Depends on:** GH-020.
**Done when:** a reflection-based `warp_of(struct) -> Warp` (or `Value` from `any`) so a scanned row renders without manual mapping; test.

### GH-044 · Whitespace control `{%- -%}` · **P2** · S
**Component:** `loom.odin` (`lex`)
**Problem:** No whitespace trimming; templates emit stray newlines around tags.
**Done when:** `-` on either delimiter trims adjacent whitespace, matching Jinja; tests.

---

## Epic 6 — Auth, Sessions, Security

### GH-050 · Cookie read/write · **P1** · M
**Component:** `bifrost.odin`, depends on header parsing
**Problem:** No cookie support at all.
**Depends on:** GH-001 (read `Cookie`), response headers (have `Set-Cookie`).
**Done when:** `cookie(b, name)` reader and `set_cookie(b, name, value, opts)` writer with HttpOnly/Secure/SameSite/Max-Age; test round-trip.

### GH-051 · Sessions · **P1** · M
**Component:** new `session.odin`
**Problem:** No session mechanism.
**Depends on:** GH-050.
**Done when:** signed session cookie (or server-side store) with get/set/clear; a default signing key from config; tamper detection test.

### GH-052 · Auth-guard middleware (the `.ward` TODO) · **P1** · M
**Component:** `middleware.odin`, `router.odin`
**Problem:** `routes.odin` has a `// .ward for auth guards` comment — a TODO, not
a feature. No way to protect routes.
**Depends on:** GH-051.
**Done when:** a `ward`/guard rune (or per-route guard) that short-circuits unauthenticated requests with `401`; documented usage; test on a protected route.

### GH-053 · CSRF protection · **P2** · M
**Component:** new middleware
**Depends on:** GH-051, GH-003 (form parsing).
**Done when:** CSRF token issued + validated on state-changing requests; test.

### GH-054 · TLS for the HTTP server · **P1** · L
**Component:** `server.odin`
**Problem:** Server is plaintext HTTP only.
**Depends on:** same TLS spike as GH-031.
**Done when:** optional HTTPS listener with cert/key from config; documented; reachable over `https://`.

---

## Epic 7 — Multi-dialect (currently Postgres-only in practice)

### GH-060 · SQLite driver · **P2** · L
**Component:** new `sqlite.odin`
**Problem:** `.SQLite` produces DDL/placeholders but has no connection or exec
path — it can only print schema.
**Done when:** a working SQLite backend (FFI to libsqlite3 or a pure-Odin path) implementing the same `exec`/`query`/`scan` seam Postgres uses.

### GH-061 · MySQL driver · **P2** · L
**Component:** new `mysql.odin`
**Problem:** Same as GH-060 for MySQL.
**Done when:** working MySQL connection + exec/query/scan behind the existing dialect seam.

---

## Epic 8 — Ops, DX, Hygiene

### GH-070 · Add README + LICENSE · **P1** · S
**Problem:** GitHub "About" is empty; there's no README or LICENSE. Onboarding
is the docs HTML site only.
**Done when:** README with quickstart, architecture map (the module table already in `app.odin` is a good seed), and build/run instructions; a LICENSE file.

### GH-071 · Stop tracking the compiled binary · **P1** · S
**Problem:** `gjallarhorn.bin` (721KB) is committed despite being in `.gitignore`
— it was added before the ignore rule, which doesn't retroactively untrack.
**Done when:** `git rm --cached gjallarhorn.bin`; confirm it stays ignored; history cleanup optional.

### GH-072 · CI: build + test on push · **P1** · S
**Problem:** No CI; 17 of 18 commits are "chore: working crud" with no signal.
**Done when:** a workflow that runs `odin build .` and `odin test ./tests` (and spins up the docker Postgres for DB tests) on every push.

### GH-073 · Structured logging · **P2** · S
**Component:** `middleware.odin` (`logger`)
**Problem:** Logging is `fmt.printfln`; the `logger` rune has a noted spot for
response timing/status that's currently empty.
**Done when:** logger emits method, path, status, and duration (fill the post-`next` position); leveled output.

### GH-074 · Resolve the `secret.txt` fixture · **P2** · S
**Problem:** `secret.txt` ("TOP-SECRET: do not serve this") looks like a
traversal fixture but no test references it.
**Done when:** either a test asserts it can't be served via traversal, or it's removed.

### GH-075 · Expand status-code table · **P2** · S
**Component:** `response.odin` (`status_text`)
**Problem:** Only a handful of statuses are mapped; everything else falls through
to `"OK"`, so a `401`/`413`/`503` gets the wrong reason phrase.
**Done when:** the common 2xx/3xx/4xx/5xx codes the framework actually emits are mapped correctly.

---

## Suggested sequencing

The critical path to "you can build a small app on this":

1. **GH-001 → GH-002 → GH-003** (read headers, then body, then decode it)
2. **GH-020** (scan rows back into structs) — in parallel; independent of the HTTP work
3. **GH-010 + GH-011** (concurrency + isolation)
4. **GH-030 + GH-031** (SCRAM + TLS, so it talks to a real Postgres)
5. **GH-050 → GH-051 → GH-052** (cookies → sessions → the `.ward` guard)

Everything in Epics 5, 7, and most of 8 is breadth/polish and can trail the
critical path. GH-070–GH-072 are cheap and worth doing early for hygiene.