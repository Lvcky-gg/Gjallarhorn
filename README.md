# ᚷ Gjallarhorn

**A from-scratch web framework in [Odin](https://odin-lang.org). No dependencies.**

Gjallarhorn is the horn Heimdall sounds at the gates of Ásgarð. Here it's a small,
honest web framework: a hand-rolled HTTP server, a router, an onion of middleware,
a template engine, and an ORM that speaks PostgreSQL over a wire protocol written
from scratch. No libpq, no third-party packages — just structs, runes, and the
well of memory.

It is young and says so. Each module documents what it does, what its security
checkpoint is, and what's deferred to a later phase. See
[Status & limitations](#status--limitations) for an unvarnished account of what
works today.

---

## Quickstart

You need the [Odin compiler](https://odin-lang.org/docs/install/) on your path.
A database is optional — without one, the framework still runs and just prints the
SQL it *would* migrate.

```sh
# 1. (optional) bring up Postgres for the ORM
docker compose up -d

# 2. run the sample app — serves on http://127.0.0.1:8091
odin run .

# 3. run the template-engine tests
odin test ./tests
```

If you skip step 1, leave `dbname` empty in `main.odin`. Migrations then print
their DDL to stdout instead of executing, and the DB-backed routes return
`503` — everything else (routing, middleware, static files, templates) works.

Try the running sample:

```sh
curl http://127.0.0.1:8091/sample/schema     # the SQL Mímir builds for the model
curl http://127.0.0.1:8091/sample/7          # a Sample row as JSON
curl http://127.0.0.1:8091/pages/hello.html  # a Loom-rendered template
curl http://127.0.0.1:8091/docs              # the static docs site
```

Want to put a real frontend in front of it? See
[Serving a frontend framework](#serving-a-frontend-framework-vue-react-) and the
companion [Vue + Vite example](https://github.com/Lvcky-gg/gjallar_vue_example).

---

## Install — use it in your own project

Odin has no central package manager: you install a package by putting its source
where the compiler can import it. Gjallarhorn depends only on `core:` and `base:`
(no third-party packages), so there is nothing else to fetch.

**Option A — vendor the directory (simplest).** Copy or clone just the framework
package into your project next to your `main.odin`, then import it by folder name:

```sh
your-app/
├── main.odin
└── gjallarhorn/        # copy of this repo's gjallarhorn/ package directory
```

```odin
import gh "gjallarhorn"   // resolves to the ./gjallarhorn subdirectory
```

**Option B — git submodule + a collection.** Track the repo and point an Odin
*collection* at it, so updates are a `git pull` away. The submodule checks out the
whole repo, whose framework lives in its inner `gjallarhorn/` package directory:

```sh
git submodule add https://github.com/lvcky-gg/gjallarhorn vendor/gjallarhorn
# framework package is now at vendor/gjallarhorn/gjallarhorn
```

```odin
import gh "shared:gjallarhorn"   // resolves to <collection-root>/gjallarhorn
```

```sh
# point the `shared` collection root at the repo checkout, so `shared:gjallarhorn`
# lands on its inner package directory
odin build . -collection:shared=vendor/gjallarhorn
```

Either way, build as usual. To turn on TLS (DB or HTTPS) add the opt-in flag — see
[TLS / HTTPS](#tls--https):

```sh
odin build .                      # plaintext; no OpenSSL dependency
odin build . -define:GJ_TLS=true  # links system libssl for TLS
```

Requirements: the [Odin compiler](https://odin-lang.org/docs/install/) on your
path, and — only for a `-define:GJ_TLS=true` build — system OpenSSL
(`libssl`/`libcrypto`).

---

## A minimal app

```odin
package main

import gh "gjallarhorn"

User :: struct {
    id:   int    `db:"id,pk,auto"`,
    name: string `db:"name,notnull"`,
}

hello :: proc(b: ^gh.Bifrost) {
    name, _ := gh.param(b, "name")
    gh.json(b, 200, User{id = 1, name = name})
}

main :: proc() {
    app := gh.new(gh.Config{
        port    = 8091,
        db_type = .Postgres,
        postgres = gh.Postgres_Config{
            host = "127.0.0.1", port = 5432,
            user = "app", password = "secret", dbname = "gjallarhorn",
        },
    })

    // Middleware ("runes"), registered onion-style, outermost first.
    gh.rune(&app, gh.logger)
    gh.rune(&app, gh.cors)

    // Let Mímir remember the model; its table is auto-migrated at run().
    gh.remember(&app, User)

    // Routes.
    gh.get(&app, "/hello/:name", hello)

    // Mount a static dir and a template dir.
    gh.hail(&app, "/static", "./public")
    gh.hail(&app, "/pages", "./templates", page_context)

    gh.run(&app)
}

page_context :: proc(b: ^gh.Bifrost) -> gh.Warp {
    return gh.warp(
        {"title", "Hello"},
        {"items", gh.list("urd", "verdandi", "skuld", allocator = context.temp_allocator)},
        allocator = context.temp_allocator,
    )
}
```

---

## The pieces

Odin is one-directory-one-package, so the whole framework lives in
`package gjallarhorn` across several files. Each feature keeps its registration
verb next to its logic.

| File | What it holds |
| --- | --- |
| `app.odin` | `App` / `Config` / `new` |
| `server.odin` | listen, the bounded worker pool, request framing, keep-alive, graceful shutdown |
| `router.odin` | routes, `get`/`post`/`put`/`patch`/`delete` (+`head`/`options`), Wards, dispatch |
| `middleware.odin` | the Rune chain: `rune`, `next`, panic recovery, built-in `cors`/`logger` |
| `bifrost.odin` | the request/response object and its helpers |
| `body.odin` | request-body decoders: `bind_json`, `form`, query/percent decoding |
| `multipart.odin` | `multipart/form-data` parsing: `files` / `upload` |
| `fetch.odin` | outbound HTTP(S) client — `fetch` / `fetch_json` to call other APIs |
| `openapi.odin` | opt-in OpenAPI docs page (Loom-woven) + `openapi.json`, from the route table |
| `response.odin` | writing HTTP/1.1 responses |
| `session.odin` | signed-cookie sessions + `cookie` / `set_cookie` |
| `auth.odin` | `login` / `logout` / `current_user` and the `require_login` Ward |
| `password.odin` | Argon2id `hash_password` / `verify_password` (PHC format) |
| `csrf.odin` | the `csrf` rune: session-backed synchronizer token |
| `ratelimit.odin` | the `rate_limit` rune: per-client token bucket |
| `observ.odin` | the `request_id` and `metrics` (Prometheus) runes |
| `log.odin` | leveled, structured logging (`logf` / `logft`) |
| `static.odin` | `hail` + traversal-safe file serving |
| `loom.odin` | HTTP glue for Loom: `render`, `html`, directory mounts |
| `loom/` | Loom, the template engine (package `loom`) |
| `mimir.odin` | Mímir, the ORM (writes *and* reads — `scan` hydrates rows into structs) |
| `postgres.odin` | a from-scratch PostgreSQL v3 wire-protocol client (SCRAM auth, pooling) |
| `sqlite.odin` | optional live SQLite backend (opt-in `-define:GJ_SQLITE=true`, links libsqlite3) |
| `tls.odin` | optional OpenSSL TLS for the DB connection and the HTTP server (opt-in) |
| `cli/` | the `gjallarhorn` CLI: `new`, `generate resource`, and `bench` (load generator) |

### Routing

Method verbs register routes; `:name` segments capture into params.

```odin
gh.get(&app, "/sample/:id", get_handler)
gh.post(&app, "/sample", create_handler)
gh.put(&app, "/sample/:id", update_handler)
gh.patch(&app, "/sample/:id", patch_handler)
gh.delete(&app, "/sample/:id", delete_handler)

// Rarely needed: HEAD is answered from the matching GET route with the body
// dropped (same headers, same Content-Length), and the `cors` rune already
// short-circuits preflight OPTIONS. Register these only for custom behaviour.
gh.head(&app, "/sample/:id", head_handler)
gh.options(&app, "/sample", options_handler)
```

A route takes an optional 4th argument — a **Ward** (auth guard); see
[Sessions, CSRF & Wards](#sessions-csrf--wards) below.

Inside a handler, the `Bifrost` is your request *and* response:

```odin
get_handler :: proc(b: ^gh.Bifrost) {
    id, ok := gh.param_int(b, "id")
    if !ok {
        gh.text(b, 400, "id must be an integer")
        return
    }
    gh.json(b, 200, Sample{id = id, name = "thing"})
}
```

Literal routes should be registered before `:param` routes that could shadow them
(`/sample/schema` before `/sample/:id`).

**Reading request data.** The `Bifrost` exposes every part of the request through
small helpers; most return `(value, ok)` so a missing field is explicit:

```odin
id, ok    := gh.param(b, "id")          // path segment  /sample/:id
id, ok    := gh.param_int(b, "id")      // same, parsed to int (ok=false if NaN)
q, ok     := gh.query_param(b, "page")  // query string  ?page=2
ua, ok    := gh.header(b, "user-agent") // request header (keys are lower-cased)
```

Bodies are decoded on demand. `bind_json` unmarshals the body into a struct and
writes a `400` for you on malformed input; `form` decodes an
`application/x-www-form-urlencoded` body into a map:

```odin
create :: proc(b: ^gh.Bifrost) {
    payload: struct { name: string }
    if !gh.bind_json(b, &payload) { return } // 400 already written on bad JSON
    gh.json(b, 201, User{name = payload.name})
}

login :: proc(b: ^gh.Bifrost) {
    fields := gh.form(b)                      // map[string]string
    user, pass := fields["user"], fields["password"]
    // ...
}
```

**File uploads.** A `multipart/form-data` body works through the same `form`
call — its text fields land in that map (so CSRF tokens and ordinary inputs
behave identically under either encoding) — while the file parts come back from
`files` / `upload`:

```odin
upload :: proc(b: ^gh.Bifrost) {
    title := gh.form(b)["title"]          // text part, same as urlencoded
    f, ok := gh.upload(b, "file")         // file part, by field name
    if !ok {
        gh.text(b, 400, "expected a `file` part")
        return
    }
    // f.filename, f.content_type, f.data ([]u8 — exact bytes)
    os.write_entire_file_from_string(f.filename, string(f.data))
}
```

`files(b)` returns every uploaded part as `map[string]Upload`. The body is parsed
once and cached on the Bifrost, so `form` and `upload` can both be called freely.

The raw body is also on the Bifrost as `b.body` (`[]u8`) and `b.body_text`
(`string`) if you need to decode it yourself. Bodies are framed by
`Content-Length` **or** `Transfer-Encoding: chunked`, and capped at
`Config.max_body` (default 1 MiB), beyond which the server returns `413` before
your handler runs. Ambiguous framing (both headers, duplicates, or a
non-canonical length) is rejected as a request-smuggling attempt.

**Writing the response.** `text`, `json`, and `html` set the status, content
type, and body in one call; `set_header` adds a response header; `not_found`
writes a `404`. The first write wins — a second `text`/`json` on the same Bifrost
is a no-op, so an early `return` after writing is safe.

**Cookies.** `cookie(b, name)` reads from the request; `set_cookie` queues a
`Set-Cookie` (each call its own header line, so several cookies coexist):

```odin
sid, ok := gh.cookie(b, "session")
gh.set_cookie(b, "session", token, gh.Cookie_Options{
    http_only = true, secure = true, same_site = .Lax, max_age = 3600,
})
gh.set_cookie(b, "session", "", gh.Cookie_Options{max_age = 0}) // delete
```

`max_age` is a `Maybe(int)`: omit it for a session cookie, `0` to expire now.
Values are stored verbatim — encode any value carrying `;`, `,`, `=`, or
whitespace yourself.

**Sessions** ride in a signed cookie — a `string->string` map the client holds,
tamper-proofed with an HMAC-SHA256 tag keyed by `Config.secret`. The server keeps
no state; a forged or edited cookie reads back as an empty session.

```odin
gh.session_set(b, "user", "freyja")   // re-signs the cookie
name, ok := gh.session_get(b, "user")
gh.session_clear(b)                    // empties + expires the cookie
```

Set `Config.secret` in production — when it's empty, sessions fall back to a
fixed, public default key and `new()` warns at startup.

### Middleware (Runes)

A Rune wraps the rest of the pipeline. Odin has no closures, so the remaining
chain is threaded through the Bifrost rather than captured — call `next(b)` to run
the next layer.

```odin
auth :: proc(b: ^gh.Bifrost, next: gh.Next) {
    // ...inspect the request, maybe short-circuit...
    next(b)  // or don't, to stop the chain
}

gh.rune(&app, auth)
```

Built-ins: `logger` (one leveled, structured line per request — colorized on a
TTY, plain RFC3339 when piped), `cors` (permissive CORS + preflight `OPTIONS`
short-circuit), `csrf` (see below), and `rate_limit`.

**Observability.** Two optional runes. `request_id` tags each request with an id
— reusing a sane inbound `X-Request-Id` (so an upstream proxy's trace carries
through), else minting one — puts it on `b.request_id`, echoes it in the response
header, and has `logger` print it, so a log line, the client's response, and the
proxy trace all line up. `metrics` counts requests by status class plus in-flight
and cumulative latency, and serves a **Prometheus** exposition at `metrics_path`
(default `/metrics`), which it excludes from its own counts.

```odin
gh.rune(&app, gh.metrics)      // outermost — times the whole chain, serves /metrics
gh.rune(&app, gh.request_id)   // before logger, so the id reaches the log + header
gh.rune(&app, gh.logger)
```
```
$ curl -s localhost:8091/metrics
gjallarhorn_requests_total{status="2xx"} 128
gjallarhorn_requests_in_flight 2
gjallarhorn_request_duration_seconds_count 128
```
`/metrics` is open when the rune is registered — bind to an internal interface or
keep it behind your proxy if it shouldn't be public.

**Custom error pages.** `on_error` replaces the framework's plain-text errors
with your own handler — the errors Gjallarhorn generates on your behalf: `404`
(no route), `500` (a handler panicked), `403` (path traversal), and the `401` a
Ward falls back to. Errors your own code writes (a rune's `403`, `bind_json`'s
`400`) stay under your control.

```odin
gh.on_error(&app, 404, proc(b: ^gh.Bifrost) {
    gh.html(b, 404, "<h1>Lost in Niflheim</h1>")
})
gh.on_error(&app, 500, my_error_page)
```

A registered handler that declines to write still falls back to the default, so
an error always gets a body. The `500` handler runs *after* panic recovery under
its own guard — if it panics too, you get the plain default instead of a crashed
worker.

**Rate limiting.** `rate_limit` is a per-client token bucket: each client gets
`rate_limit_burst` tokens refilling at `rate_limit_rps` per second, so bursts
pass untouched and only sustained excess is refused — with a `429` and a
`Retry-After` saying when the next token lands. It pairs with the bounded worker
pool: the pool caps how much work runs at once, this caps how fast one client can
ask for it.

```odin
gh.rate_limit_rps   = 20        // sustained requests/second per client (default 10)
gh.rate_limit_burst = 40        // burst forgiven at once           (default 20)
gh.rune(&app, gh.rate_limit)
```

Clients are keyed by the peer address captured at accept. Behind a reverse proxy
every request would otherwise share the proxy's bucket, so set
`gh.rate_limit_trust_forwarded = true` to key on `X-Forwarded-For` instead —
**only** when a trusted proxy sets that header, since clients can forge it. Idle
buckets are swept periodically so the table can't grow without bound.

### Sessions, CSRF & Wards

The session is a small `string → string` map that rides in a cookie the client
holds — the server keeps no state. An **HMAC-SHA256** tag over the payload (keyed
by `Config.secret`) makes it unforgeable, and the expiry is signed *inside* the
tag, so a client can't extend its own session by editing the cookie. `Secure` is
set automatically over TLS.

```odin
gh.session_set(b, "theme", "dark")
theme, ok := gh.session_get(b, "theme")
gh.session_delete(b, "theme")
gh.session_clear(b)                       // and expire the cookie
```

**Login** is a thin layer on that: `login` records a user id in the signed
session, and a **Ward** gates routes on it. A Ward is just
`proc(b: ^Bifrost) -> bool` — return `true` to admit; on `false` the handler is
skipped (write your own status, or dispatch falls back to `401`).

```odin
gh.login(b, "user-42")                    // after you verify a password/OTP
uid, ok := gh.current_user(b)
gh.logout(b)

// Built-in ward; or write your own for roles/ownership.
gh.get(&app, "/account", account_handler, gh.require_login)
```

**Passwords.** `login` deliberately assumes you've already checked the
credentials — `hash_password` / `verify_password` are that check. They use
**Argon2id** (RFC 9106) with OWASP's recommended cost, a fresh 16-byte CSPRNG
salt per password, and a constant-time comparison. The result is a standard PHC
string you store verbatim:

```odin
// at signup
stored, ok := gh.hash_password(fields["password"], context.allocator)
// -> "$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>"

// at login
if !gh.verify_password(fields["password"], stored) {
    gh.text(b, 401, "invalid username or password")   // same answer for both cases
    return
}
gh.login(b, user_id)
```

Because the salt and cost travel inside the hash, raising `gh.PASSWORD_PARAMS`
later doesn't invalidate existing hashes — they keep verifying at the cost they
were made with. Hashing is *meant* to be slow (~19 MiB per call), which makes a
login endpoint a natural DoS target, so pair it with the `rate_limit` rune.

**CSRF** is a session-backed synchronizer token, registered as a rune. Safe
methods (GET/HEAD/OPTIONS) seed a token; unsafe ones must echo it back in the
`X-CSRF-Token` header or a `csrf_token` form field (compared in constant time),
else `403`.

```odin
gh.rune(&app, gh.csrf)
token := gh.csrf_token(b)   // embed in a form or hand to fetch()
```

> **Set a real secret.** `Config.secret` signs sessions and CSRF tokens. A
> release build **refuses to start** on an empty or default secret; a `-debug`
> build warns and continues.

### Mímir — the ORM

Your structs describe a shape; `db:` tags drive everything. Mímir remembers the
shape and migrates it to a table at `run()`.

```odin
Sample :: struct {
    id:   int    `db:"id,pk,auto"`,    // auto-assigned primary key
    name: string `db:"name,notnull"`,  // required text column
}
```

Tag flags: `pk`, `auto`, `unique`, `notnull`, a custom column name, or `-` to
skip a field. The query verbs follow the well's vocabulary:

| Verb | SQL | Meaning |
| --- | --- | --- |
| `carve` | `CREATE TABLE` | carve a struct's shape into the well |
| `offer` | `INSERT` | offer a value to the well |
| `recall` | `SELECT` | recall rows (a `Query` you refine, then `sql`) |
| `amend` | `UPDATE` | amend a remembered row by primary key |
| `forget` | `DELETE` | make the well forget a row by primary key |

```odin
w := gh.well(b)

q := gh.recall(w, Sample)
gh.whose(&q, "id = ?", 7)
gh.limit(&q, 1)
rows, ok := gh.query(w, gh.sql(&q))
```

**Reading rows back into structs.** `query` returns `Pg_Rows` (text cells);
`scan` hydrates every row into a freshly allocated `[]T`, and `scan_one` returns
just the first row with an `ok` for the empty case. Columns map to fields by `db:`
name (else the field name); a SQL `NULL` becomes the field's zero value.

```odin
rows, ok := gh.query(w, gh.sql(&q))
users := gh.scan(rows, User)            // []User
one, found := gh.scan_one(rows, User)   // (User, bool)
```

**Supported field types.** Each maps to a Postgres column both directions — the
DDL Mímir carves, the bound parameter it writes, and the value `scan` hydrates
back:

| Odin type | Postgres column |
|---|---|
| int family (`int`, `i8`…`i64`, `u8`…`u64`) | `BIGINT` |
| `f32` / `f64` | `DOUBLE PRECISION` |
| `bool` | `BOOLEAN` |
| `string` | `TEXT` |
| `time.Time` | `TIMESTAMPTZ` |
| `[]u8` | `BYTEA` |
| `gh.Uuid` (alias of `core:encoding/uuid.Identifier`) | `UUID` |
| `gh.Json` (raw JSON text) | `JSONB` |

Wrap any of them in **`Maybe(T)`** to make the column nullable: a SQL `NULL`
hydrates as `None` and a value as `Some(v)`, so `NULL` is never conflated with a
zero or empty value — and on the write side `None` binds as a real `NULL`.

```odin
Event :: struct {
    id:   int              `db:"id,pk,auto"`,
    at:   time.Time        `db:"at"`,      // TIMESTAMPTZ
    ref:  gh.Uuid          `db:"ref"`,     // UUID
    blob: []u8             `db:"blob"`,    // BYTEA
    meta: gh.Json          `db:"meta"`,    // JSONB
    note: Maybe(string)    `db:"note"`,    // nullable TEXT
}
```

**Writes** use the same `query` verb with `offer`/`amend`/`forget`, or `exec`
when you don't need the returned rows:

```odin
gh.query(w, gh.offer(w, User{name = "freyja"}))          // INSERT
gh.query(w, gh.amend(w, User{id = 1, name = "renamed"}))  // UPDATE by pk
gh.query(w, gh.forget(w, User{id = 1}))                   // DELETE by pk
```

**Transactions.** `tx` checks out one pooled connection, wraps your closure in
`BEGIN`/`COMMIT`, and rolls back if it returns `false` (or any statement fails).
Every statement on the handed-in `Well` runs on that one connection:

```odin
ok := gh.tx(w, proc(w: gh.Well) -> bool {
    _, a := gh.query(w, gh.offer(w, User{name = "a"}))
    _, b := gh.query(w, gh.offer(w, User{name = "b"}))
    return a && b // either insert failing rolls back both
})
```

**SQL injection is the checkpoint here:** values never reach the SQL string. Every
value is a bound parameter (`$1..` for Postgres, `?` otherwise).

Set `db_type` to `.Postgres`, `.MySQL`, or `.SQLite`. DDL is generated for all
three; **Postgres and SQLite have live drivers**, MySQL is DDL-only for now.

### SQLite — an opt-in embedded backend

SQLite runs the same `query`/`exec`/`scan`/`tx` path against a local file (or
`:memory:`). It links the system **libsqlite3**, so — like TLS — it's opt-in
behind a build flag, keeping the default build dependency-free:

```odin
app := gh.new(gh.Config{ db_type = .SQLite, sqlite = "app.db" }) // or ":memory:"
```
```sh
odin build . -define:GJ_SQLITE=true    # links libsqlite3
```

Mímir already emits SQLite DDL and `?` placeholders, and `scan` reads text
cells, so the backend just opens a (serialized, mutex-guarded) connection, binds
arguments as text, and marshals rows into the same shape Postgres returns —
including the NULL-vs-empty distinction and transactions. A default build without
the flag fails loudly if you select `.SQLite`.

### Postgres — a hand-rolled wire client

`postgres.odin` implements the PostgreSQL v3 frontend/backend protocol directly
over `core:net`: StartupMessage, the extended query flow (Parse / Bind / Describe
/ Execute / Sync), and RowDescription/DataRow parsing. Connections are pooled
(`Config.pool_size`, default 4) and checked out per request.

**Auth:** trust, cleartext, MD5, and **SCRAM-SHA-256** — the default for stock
modern Postgres — so no `pg_hba.conf` downgrade is needed to connect to a
default-configured server.

**TLS (optional).** Set `Postgres_Config.sslmode` to negotiate TLS before the
startup handshake, so the password and all queries cross the wire encrypted:

```odin
postgres = gh.Postgres_Config{
    host = "db.example.com", port = 5432,
    user = "app", password = "secret", dbname = "gjallarhorn",
    sslmode = .Require,   // .Disable (default) / .Prefer / .Require / .Verify_Full
}
```

| `sslmode` | Behaviour |
| --- | --- |
| `.Disable` | no TLS; cleartext (the default — unchanged behaviour) |
| `.Prefer` | use TLS if the server offers it, else fall back to cleartext |
| `.Require` | TLS mandatory; certificate **not** verified |
| `.Verify_Full` | TLS mandatory; verify the cert chain + hostname against the system CA bundle |

Any mode other than `.Disable` requires a TLS build — see
[TLS / HTTPS](#tls--https) below. Without it, startup fails loudly rather than
silently sending the password in the clear.

### Loom — the template engine

A Jinja subset, pared to its load-bearing parts. The Norns weave fate at the well;
here `weave` runs your data (the weft) through a template (the warp).

```html
<h1>{{ title }}</h1>
<p>Hail, {{ user.name }}{% if user.admin %} <strong>(admin)</strong>{% endif %}.</p>

{% if items %}
<ol>
{% for item in items %}
  <li>#{{ loop.index }} — {{ item | upper }}{% if loop.last %} (last){% endif %}</li>
{% endfor %}
</ol>
{% else %}
<p>Nothing woven yet.</p>
{% endif %}
```

Supported: `{{ expr }}`, filter pipelines (`upper`, `lower`, `trim`, `capitalize`,
`length`, `default`, `join`, `first`, `last`, `safe`, `escape`), `{% if %}` /
`{% elif %}` / `{% else %}`, `{% for x in xs %}` with `{% else %}` for the empty
case and a Jinja-style `loop` (`index`, `index0`, `first`, `last`, `length`), and
`{# comments #}`. A `-` on either delimiter (`{%- … -%}`, `{{- … -}}`, `{#- … -#}`)
trims adjacent whitespace, so tags don't leave stray newlines.

**Template inheritance** — a child names a base with `{% extends "base.html" %}`
and overrides its named blocks; blocks it leaves alone keep the base's default:

```html
<!-- base.html -->
<html><body>{% block content %}default{% endblock %}</body></html>

<!-- page.html -->
{% extends "base.html" %}
{% block content %}<h1>{{ title }}</h1>{% endblock %}
```

Bases resolve against the template's own mount dir, and `{% extends %}` chains
(grandchild → child → base) — the most-derived override of a block wins.

**Includes** — `{% include "partial.html" %}` renders another template inline
with the current context (loop vars and all). Partials resolve their own
inheritance, so an included file may itself `{% extends %}` a base.

**Macros** — reusable fragments, defined once and called like a function.
`{% import "forms.html" %}` pulls another file's macros into the current template.

```html
{% macro field(name, label) %}
  <label>{{ label }} <input name="{{ name }}"></label>
{% endmacro %}

{{ field("email", "Email") }}   <!-- -> <label>Email <input name="email"></label> -->
```

A macro sees only its arguments — not the caller's local variables — so it's a
predictable, self-contained unit. Its body is treated as markup (not
re-escaped), while `{{ param }}` interpolations inside it *are* escaped, so it's
XSS-safe by default. Calls are hoisted, so one may appear before its definition.
Arguments are positional (no keyword args or defaults yet); a missing argument is
empty, and calling an undefined macro renders nothing.

**Path traversal is the checkpoint here too:** `extends`/`include` names are
clamped to the mount dir (same clean-and-contain check as the static mounts), so
`{% include "../../etc/passwd" %}` is refused.

Templates served from disk are parsed once and cached by path + mtime, so a hot
page is lexed and parsed only on its first hit and re-parsed only when the file
changes — the per-render cost drops to evaluation and output.

**Typed rows render directly.** `warp_of` reflects a struct (a scanned Mímir row,
say) into a context keyed by field name — no hand-built map:

```odin
gh.render(b, "user.html", gh.warp_of(row))           // {{ name }}, {{ admin }}
gh.warp({"users", gh.value_of(rows)})                // a slice -> {% for u in users %}
```

Nested structs become nested contexts (`{{ profile.city }}`) and slices iterate.
A `loom:"alias"` field tag renames the key for templates; `loom:"-"` hides it.

**XSS is the checkpoint here:** output is HTML-escaped by default. Safety rides
with the value as it's evaluated, so it's decided per output — pipe through
`| safe` to emit verbatim.

### Static files

```odin
gh.hail(&app, "/static", "./public")              // raw files
gh.hail(&app, "/pages", "./templates", provider)  // files woven by Loom
```

**Path traversal is the checkpoint here:** a resolved path is cleaned and must
stay inside the mount root, else `403`.

**Caching.** Every static file is served with an `ETag` (from its size + mtime),
`Last-Modified`, and `Cache-Control`. A conditional re-request that still matches
— `If-None-Match` (ETag) or `If-Modified-Since` — gets a **`304 Not Modified`
with no body**, so a returning visitor re-downloads nothing until the file
actually changes. Tune the policy with `gh.static_cache_control` (default
`"public, max-age=3600"`; for content-hashed filenames, `"public,
max-age=31536000, immutable"`).

**Precompressed gzip (`gzip_static`).** If a sibling `<file>.gz` exists and the
client sent `Accept-Encoding: gzip`, that file is served with
`Content-Encoding: gzip` and `Vary: Accept-Encoding` — typed by the *original*
extension. Compress your assets ahead of time (`gzip -k style.css`) or in your
build. Gjallarhorn does **not** compress on the fly: Odin's core ships a gzip
*decompressor* but no compressor, and a default build takes no third-party deps
(same stance as TLS).

---

### Fetch — calling other APIs

Handlers often need to call *out* — a payment gateway, a webhook, another
service. `fetch` is a small outbound HTTP(S) client built from the same pieces as
the server: `net` for the socket, `wire_send`/`wire_recv` (which already abstract
plaintext vs TLS), and `parse_headers` for the response. It sends
`Connection: close`, reads to EOF, and de-chunks a chunked reply.

```odin
res, ok := gh.fetch("https://api.example.com/v1/things")
if ok && res.status == 200 {
    payload: My_Type
    json.unmarshal(res.body_bytes, &payload)   // res.body is the same bytes as string
}
```

The zero-value request is a plain `GET`. Set a method, headers, or a body through
`Fetch_Request`; response `headers` keys are lower-cased, so
`res.headers["content-type"]` works regardless of how the server cased it:

```odin
res, ok := gh.fetch("https://api.example.com/things", gh.Fetch_Request{
    method  = "POST",
    headers = {"Authorization" = "Bearer …"},
    body    = `{"name":"skuld"}`,
    timeout = 5 * time.Second,               // 0 -> FETCH_TIMEOUT (30s)
})
```

`fetch_json` is the same call with a JSON body: it marshals the payload and sets
`Content-Type: application/json` for you.

```odin
res, ok := gh.fetch_json("POST", "https://api.example.com/things", My_Type{…})
```

`ok` is false only on a **transport** failure (DNS, connect, TLS, or no parseable
response) — a `4xx`/`5xx` still returns `ok=true` with `res.status` set. Redirects
are returned, not followed (read `res.headers["location"]`). An `https://` URL
needs a **`-define:GJ_TLS=true`** build (same OpenSSL gate as the DB and server);
without it, an https fetch fails fast rather than falling back to plaintext.

---

### OpenAPI docs — a self-describing API, with a live "Try it"

Flip one config flag and Gjallarhorn serves a docs page — **woven by Loom** — plus
an `openapi.json` document, both generated from the route table the router already
holds. Nothing to keep in sync: register a route and it appears; it's off by
default, so a public app pays nothing until it opts in.

```odin
app := gh.new(gh.Config{
    port = 8091,
    docs = gh.Docs_Config{
        enabled     = true,               // off by default
        title       = "My API",           // shown on the page + in the spec
        version     = "1.2.0",
        description = "What this service does.",
        // path     = "/api-docs",        // where to mount (this is the default)
    },
})
```

That mounts two GET routes:

- **`/api-docs`** — an interactive page. Each endpoint expands to a **Try it** panel
  with inputs for its path parameters, an editable JSON request body, and an
  **Execute** button that fires the request **from the browser** (a plain `fetch`,
  same origin) and shows the live status and response. Ward-guarded routes carry a
  🔒. It's a Loom template carried in the binary — inline CSS + a little vanilla JS,
  no external assets, no Swagger-UI CDN.
- **`/api-docs/openapi.json`** — a valid **OpenAPI 3.0.3** document. `:id` segments
  become `{id}` path parameters, methods on a shared path are grouped, and a guarded
  route advertises a `401`.

**Give a route its schema with `describe`.** Point it at the Odin request/response
types and Gjallarhorn reflects them into JSON Schema (and a filled-in example body
for the Try-it form) — the same reflection Mímir uses, so a model documents itself:

```odin
gh.get(&app, "/sample/:id", get_handler)
gh.describe(&app, .Get, "/sample/:id", {summary = "Fetch one sample", response = Sample})

gh.post(&app, "/sample", create_handler)
gh.describe(&app, .Post, "/sample", {request = Sample, response = Sample})
```

`describe` is optional and additive — an undescribed route still lists, just
without a body schema. The reflection maps the same column types Mímir does
(`int`/`float`/`bool`/`string`, `time.Time`, `[]u8`, `uuid`, `JSONB`) and renders
a `Maybe(T)` field as a `nullable` property; nested structs and slices recurse.
Property names follow a `json:"…"` tag when present, else the field name (what
`json.marshal` would emit). What *isn't* described is omitted rather than invented.

Because Execute sends a real request, it passes through your middleware: a `POST`
to a route behind the `csrf` rune (or a Ward, or the rate limiter) gets the same
`403`/`401`/`429` a browser would — which is usually the right thing to see. Pure
JSON APIs typically don't enable CSRF, so their Try-it just works. You can also
point any external tool (Swagger UI, `openapi-generator`, Insomnia) at the
`openapi.json` URL.

---

## TLS / HTTPS

TLS is **opt-in at build time**. Odin ships no TLS in `core` or `vendor`, so
Gjallarhorn binds the system OpenSSL (`libssl`/`libcrypto`) — but the whole
binding lives behind a compile flag, so a default build links **no** libssl and
doesn't need OpenSSL installed at all:

```sh
odin run .                       # plaintext: no OpenSSL needed, nothing linked
odin run . -define:GJ_TLS=true   # links libssl; enables DB TLS + HTTPS
```

A TLS build needs OpenSSL's development library present at build time and the
runtime library at run time (`libssl` + `libcrypto`, 1.1.x or 3.x). If you
configure TLS but build without `-define:GJ_TLS=true`, startup fails loudly
instead of silently falling back to an unencrypted connection.

**HTTPS server.** Point `Config` at a PEM certificate and key; the listener then
serves `https://` instead of `http://`:

```odin
app := gh.new(gh.Config{
    port     = 8443,
    tls_cert = "server.crt", // PEM certificate chain
    tls_key  = "server.key", // PEM private key
})
gh.run(&app) // logs: listening on https://127.0.0.1:8443
```

```sh
odin run . -define:GJ_TLS=true
```

For local testing, a self-signed pair is enough:

```sh
openssl req -new -x509 -days 365 -nodes \
  -out server.crt -keyout server.key \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

curl --cacert server.crt https://localhost:8443/      # verifies the chain
curl -k https://localhost:8443/                        # or skip verification
```

**Database TLS** uses the same build flag — set `Postgres_Config.sslmode` (see
[Postgres](#postgres--a-hand-rolled-wire-client)). The DB client and HTTP server
share one `tls.odin` module.

*Scope:* a single listener is HTTP **or** HTTPS (no dual-port and no HTTP→HTTPS
redirect); `.Verify_Full` trusts the system CA bundle (no custom-CA option yet);
certs load once at boot (no hot reload on renewal).

---

## Serving a frontend framework (Vue, React, …)

Gjallarhorn can be the only server in front of a modern SPA: build the frontend
to static assets and let `hail` serve them. There's no separate Node server in
production — the Odin binary serves the framework's compiled bundle directly.

A worked example lives in its own repo,
**[gjallar_vue_example](https://github.com/Lvcky-gg/gjallar_vue_example)** — a
Vue 3 + Vite app built to `dist/` and served by Gjallarhorn:

```odin
package main

import gh "gjallarhorn"

main :: proc() {
    app := gh.new(gh.Config{port = 3000})

    // Serve the Vite build output under /test. A bare directory request
    // (GET /test/) falls back to the bundle's index.html.
    gh.hail(&app, "/test", "./gjallar-example/dist/")

    gh.run(&app)
}
```

```sh
perl ./install-deps.perl                                   # fetch the framework
cd ./gjallar-example && npm install && npm run build && cd ..
odin run .                                                 # serve on :3000
# open http://localhost:3000/test/
```

The one thing that must line up is the **mount path and the build's asset base**:
Vite's `base` (in `vite.config.*`) has to match the `hail` prefix, or the bundle's
`/assets/…` URLs 404. With `hail(&app, "/test", …)`, set `base: "/test/"`.

The same pattern works for any framework that builds to a static directory
(React/Vite, Svelte, plain `esbuild` output): point `hail` at the build folder.
You can also mix it with API routes — register your `gh.get`/`gh.post` handlers
under, say, `/api/…` and mount the SPA under `/`, since explicit routes are
matched before static mounts.

---

## Lifecycle

A request crosses Bifrost in order: a worker in `server.odin` frames the request
and builds a `Bifrost`, the rune chain runs outermost-first via `next`, and when
the chain is exhausted `dispatch_route` matches a route (or a static/template
mount), runs its Ward if it has one, and calls the handler — which writes the
response back through the same Bifrost.

**Concurrency.** `run()` starts a fixed pool of `Config.workers` threads, each
accepting on the shared listening socket, so a connection flood can't spawn
unbounded threads. Excess connections wait in the kernel backlog. Each worker
owns its own temp allocator, reset per request. The default is **core-relative**
(`cores × 16`, clamped to `[16, 256]`) — the benchmark below showed a fixed 256
oversubscribes small boxes. Override with `Config.workers` for your traffic.

**Shutdown.** `SIGINT`/`SIGTERM` flip a shutdown flag: workers stop accepting,
finish the request in flight, and decline to read another on a kept-alive
connection; `run()` joins them, closes the DB pool, and returns cleanly.
`SIGPIPE` is ignored, so a client hanging up mid-response returns an error
instead of killing the process.

---

## Performance — and "should it be an event loop?"

The server is a **bounded thread pool**, not an event loop. `gjallarhorn bench`
(a self-contained load generator, `cli/bench.odin`) answers what that costs.
Numbers below are loopback on an 8-core box, so they measure the framework, not a
network — treat them as ratios, not absolutes.

```sh
gjallarhorn bench load http://127.0.0.1:8091/docs/index.html -c 50 -d 5
gjallarhorn bench hold http://127.0.0.1:8091/ -c 60 -d 14   # pin 60 workers idle
```

- **It's fast and scales.** ~350k req/s serving a static file, flat from 8 to 256
  concurrent clients, p99 under 1 ms. A cached Loom render measures the same as a
  static read — the parse cache does its job.
- **Keep-alive matters ~4×.** 358k req/s with keep-alive vs 85k when every request
  reopens the connection (accept + handshake + thread dispatch dominate).
- **Oversubscription has a cliff.** At 200 clients, 16–64 workers gave ~360k
  req/s; **256 workers gave only ~126k** (p99 6 ms) — too many threads thrash. The
  sweet spot tracks core count, which is why the default `Config.workers` is now
  `cores × 16` (clamped `[16, 256]`) rather than a flat 256.
- **Idle keep-alive connections are the real limit (head-of-line).** Holding 60 of
  64 workers with idle-but-open connections cut throughput for everyone else
  ~2.6× (350k → 137k); hold *all* of them and new clients wait in the kernel
  backlog until the idle timeout. This is the one place an event loop wins — an
  idle connection there costs a file descriptor, not a thread.

**Verdict:** for ordinary traffic (active clients, keep-alive, ideally a reverse
proxy absorbing slow ones) the pool is more than enough — no event loop needed.
Reach for one only if the goal becomes serving *many mostly-idle long-lived*
connections directly (websockets, long-poll, slow mobile clients with no proxy).

---

## Status & limitations

**Working today:** request headers, query params, and bodies in all three shapes
(JSON, url-encoded, and `multipart/form-data` file uploads); every method verb
(`get`/`post`/`put`/`patch`/`delete`, plus `head`/`options`, with HEAD answered
from the GET route); HTTP keep-alive, chunked transfer decoding, and pipelining;
a **bounded worker pool** with **graceful SIGTERM/SIGINT drain**; per-request
panic recovery; cookies and HMAC-signed sessions with server-enforced expiry;
**CSRF** protection, per-client **rate limiting**, custom **error pages**, **Wards** (per-route auth
guards) with `login`/`logout`/`current_user`, and **Argon2id password hashing**; the ORM's full read/write/transaction path with struct hydration
over `int`/`float`/`bool`/`string`, `time.Time`, `uuid`, `bytea`, `JSONB`, and
`Maybe(T)` nullables; SCRAM-SHA-256 auth; connection pooling; an optional live SQLite backend; optional TLS on
both the DB connection and the HTTP server; static-file caching (ETag /
Last-Modified / conditional `304`) and precompressed `gzip_static`; template
inheritance, includes, macros, whitespace control, the compiled-node cache, and
direct struct rendering; leveled/structured logging with request IDs and a Prometheus /metrics endpoint; an outbound HTTP(S) client for calling other APIs; an opt-in Loom-woven OpenAPI docs page (reflected schemas + a live in-browser "Try it") + `openapi.json`; a scaffolding CLI; and CI
that tests and publishes to the AUR on every push to `main`.

**Known gaps**, in rough order of impact:

- **MySQL has no live driver.** All three dialects generate DDL, and **SQLite is
  a live backend** (opt-in: `-define:GJ_SQLITE=true`, links libsqlite3); MySQL
  still generates DDL only, so `query`/`exec` don't run against it yet.
- **Keep-alive holds a worker.** Concurrency is bounded (`Config.workers`,
  default 256) rather than unbounded, but a slow client still occupies its worker
  for the connection's life — size the pool accordingly.
- **Macros are positional-only.** `{% macro %}` / `{{ call(args) }}` / `{% import %}`
  are in, but without Jinja's keyword args, defaults, or namespaced import
  (`import … as`); an imported macro shares the global macro namespace.
- **No on-the-fly compression.** gzip is precompressed-only (`gzip_static`) —
  Odin core has a gzip decompressor but no compressor, and a default build adds
  no third-party deps. Precompress assets in your build, or put a compressing
  proxy in front.
- **TLS is opt-in and depends on system OpenSSL** (by design — a default build has
  no TLS and no libssl). `.Verify_Full` trusts only the system CA bundle, and
  certs are loaded once at boot.
- **Multipart filenames containing `;`** split early — the part-header parser is
  deliberately simpler than a full RFC 2045 quoted-string parser.

Contributions toward any of the above are the most useful place to start.

---

## The CLI — scaffolding (`nest`-style)

**Arch Linux (AUR):** install the `gjallarhorn` command:

```sh
yay -S gjallarhorn-git          # or: paru -S gjallarhorn-git
gjallarhorn new blog            # command is `gjallarhorn` once installed
```

The package installs the `gjallarhorn` binary plus the framework source (under
`/usr/share/gjallarhorn`), which `gjallarhorn new` vendors into your project — so
you don't need a checkout. (`GJALLARHORN_LIB` overrides that source path.)

**From a checkout**, build the CLI yourself:

```sh
odin build cli -out:gh          # or run inline: odin run cli -- <args>
```

(Examples below use `gh`; substitute `gjallarhorn` when installed from the AUR.)

### `gh new <app>` — a whole new app

Scaffolds a new, **immediately runnable** project — a minimal `main.odin`, a
`docker-compose.yml` for Postgres, a `.gitignore`, and a vendored copy of the
framework (when run from a checkout that has `./gjallarhorn`):

```sh
./gh new blog
cd blog && odin run .           # -> http://127.0.0.1:8091/hello/world
```

The starter `main.odin` boots without a database (a `/hello/:name` route); the
ORM config is there commented out, ready to uncomment.

### `gh generate resource <name>` — a CRUD resource

Generates a `model` + `controller` + `routes` trio mirroring `./sample` (alias
`g res`):

```sh
./gh generate resource users
#   created users/model.odin  users/controller.odin  users/routes.odin
```

The resource name is plural; the model struct is its singular (`users` → `User`),
so Mímir's table comes out as `users`. It never overwrites existing files. Wire
it into `main.odin` as the command prints:

```odin
import "users"
// ...inside main(), after gh.new():
users.register(&app)   // remembers the model + registers GET/POST/PUT/DELETE
```

That gives you `GET /users/:id`, `POST /users`, `PUT /users/:id`,
`DELETE /users/:id` — edit `users/model.odin` to shape the table.

### `gh docs [topic]` — browse the docs in your terminal

A self-contained terminal UI (raw-mode termios + ANSI, no dependencies) that walks
the whole framework by topic — Mímir, Loom, the runes, sessions, fetch, and the
rest — as a two-pane table: topics on the left, detail on the right.

```sh
./gh docs                 # open the browser
./gh docs loom            # jump straight to a topic (prefix match)
./gh docs --plain         # dump every topic as text (piping / no TTY)
```

Navigate with `↑`/`↓` or `j`/`k`, page the detail with `space`/`b`, `g`/`G` for
top/end, `q` to quit. When stdout isn't a terminal it falls back to the plain-text
dump automatically, so `gh docs | less` and `gh docs > DOCS.txt` just work.

## Project layout

```
.
├── gjallarhorn/        # the framework (package gjallarhorn)
├── cli/                # the `gjallarhorn` CLI: scaffolding + `bench` load generator
├── sample/             # a small MVC example app
├── templates/          # Loom templates served at /pages
├── docs/               # the static docs site served at /docs
├── tests/              # Loom engine tests (odin test ./tests)
├── docker-compose.yml  # a local Postgres for the ORM
└── main.odin           # wires the sample app together
```

---