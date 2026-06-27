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
| `server.odin` | listen / accept (one thread per connection) / request parsing / keep-alive |
| `router.odin` | routes, `get`/`post`/`put`/`delete`, path matching + dispatch |
| `middleware.odin` | the Rune chain: `rune`, `next`, and built-in `cors`, `logger` |
| `bifrost.odin` | the request/response object and its helpers |
| `body.odin` | request-body decoders: `bind_json`, `form`, query/percent decoding |
| `response.odin` | writing HTTP/1.1 responses |
| `session.odin` | signed-cookie sessions + `cookie` / `set_cookie` |
| `static.odin` | `hail` + traversal-safe file serving |
| `loom.odin` | HTTP glue for Loom: `render`, `html`, directory mounts |
| `loom/` | Loom, the template engine (package `loom`) |
| `mimir.odin` | Mímir, the ORM (writes *and* reads — `scan` hydrates rows into structs) |
| `postgres.odin` | a from-scratch PostgreSQL v3 wire-protocol client (SCRAM auth, pooling) |
| `tls.odin` | optional OpenSSL TLS for the DB connection and the HTTP server (opt-in) |

### Routing

Method verbs register routes; `:name` segments capture into params.

```odin
gh.get(&app, "/sample/:id", get_handler)
gh.post(&app, "/sample", create_handler)
gh.put(&app, "/sample/:id", update_handler)
gh.delete(&app, "/sample/:id", delete_handler)
```

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

The raw body is also on the Bifrost as `b.body` (`[]u8`) and `b.body_text`
(`string`) if you need to decode it yourself. Bodies are framed by
`Content-Length` and capped at `Config.max_body` (default 1 MiB), beyond which the
server returns `413` before your handler runs.

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

Built-ins: `logger` (one line per request) and `cors` (permissive CORS +
preflight `OPTIONS` short-circuit).

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

Supported field types: the int family, `f32`/`f64`, `bool`, and `string`.

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
three; the live driver today is Postgres (see limitations).

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

## Lifecycle

A request crosses Bifrost in order: the socket loop in `server.odin` parses the
request line and builds a `Bifrost`, the rune chain runs outermost-first via
`next`, and when the chain is exhausted `dispatch_route` matches a route (or a
static/template mount) and calls the handler, which writes the response back
through the same Bifrost.

---

## Status & limitations

**Working today:** request headers, bodies (JSON + form) and query params; HTTP
keep-alive; one-thread-per-connection concurrency; configurable bind address;
per-request panic recovery; cookies and signed-cookie sessions; the ORM's full
read/write/transaction path with struct hydration; SCRAM-SHA-256 auth; connection
pooling; optional TLS on both the DB connection and the HTTP server; template
inheritance, includes, whitespace control, the compiled-node cache, and direct
struct rendering.

**Known gaps**, in rough order of impact:

- **Postgres-only in practice.** MySQL and SQLite generate DDL but have no live
  driver yet, so `query`/`exec` only run against Postgres.
- **No auth-guard middleware or CSRF protection** yet — the `.ward` in the sample
  is still a TODO. Sessions and cookies exist to build these on.
- **Templates have no `{% macro %}`.** Inheritance, includes, and whitespace
  control are in; macros are not.
- **TLS is opt-in and depends on system OpenSSL** (by design — a default build has
  no TLS and no libssl). `.Verify_Full` trusts only the system CA bundle, and
  certs are loaded once at boot.
- **No structured logging or CI** yet (the built-in `logger` writes one plain
  line per request).

A full backlog with fix guides lives alongside this project (`backlog.md`).
Contributions toward any of the above are the most useful place to start.

---

## Project layout

```
.
├── gjallarhorn/        # the framework (package gjallarhorn)
├── sample/             # a small MVC example app
├── templates/          # Loom templates served at /pages
├── docs/               # the static docs site served at /docs
├── tests/              # Loom engine tests (odin test ./tests)
├── docker-compose.yml  # a local Postgres for the ORM
└── main.odin           # wires the sample app together
```

---