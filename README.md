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
| `server.odin` | listen / accept / request parsing |
| `router.odin` | routes, `get`/`post`/`put`/`delete`, path matching + dispatch |
| `middleware.odin` | the Rune chain: `rune`, `next`, and built-in `cors`, `logger` |
| `bifrost.odin` | the request/response object and its helpers |
| `response.odin` | writing HTTP/1.1 responses |
| `static.odin` | `hail` + traversal-safe file serving |
| `loom.odin` | Loom, the template engine |
| `mimir.odin` | Mímir, the ORM |
| `postgres.odin` | a from-scratch PostgreSQL v3 wire-protocol client |

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

Helpers: `param`, `param_int`, `text`, `json`, `set_header`, `not_found`.
Literal routes should be registered before `:param` routes that could shadow them
(`/sample/schema` before `/sample/:id`).

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

**SQL injection is the checkpoint here:** values never reach the SQL string. Every
value is a bound parameter (`$1..` for Postgres, `?` otherwise).

Set `db_type` to `.Postgres`, `.MySQL`, or `.SQLite`. DDL is generated for all
three; the live driver today is Postgres (see limitations).

### Postgres — a hand-rolled wire client

`postgres.odin` implements the PostgreSQL v3 frontend/backend protocol directly
over `core:net`: StartupMessage, the extended query flow (Parse / Bind / Describe
/ Execute / Sync), and RowDescription/DataRow parsing. **Auth:** trust, cleartext,
and MD5. SASL/SCRAM is detected but not yet implemented — use `md5` or `trust` in
`pg_hba.conf` (the bundled `docker-compose.yml` uses `trust`).

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
`{# comments #}`.

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

## Lifecycle

A request crosses Bifrost in order: the socket loop in `server.odin` parses the
request line and builds a `Bifrost`, the rune chain runs outermost-first via
`next`, and when the chain is exhausted `dispatch_route` matches a route (or a
static/template mount) and calls the handler, which writes the response back
through the same Bifrost.

---

## Status & limitations

Gjallarhorn has a coherent spine and two genuinely above-toy pieces (the
from-scratch Postgres client and a real template engine with correct escaping).
It is **not yet ready for a production app.** Known gaps, in rough order of impact:

- **No request body or header parsing.** The server reads only the request line;
  request headers and bodies are not yet available to handlers. The sample passes
  data through path params as a stopgap. (No JSON/form bodies, cookies, or auth
  headers yet.)
- **The ORM writes but doesn't read back into structs.** Queries return rows as
  `[][]string`; there's no scan into typed structs yet, so you parse columns by
  hand.
- **Single-threaded, blocking server.** One connection at a time, `Connection:
  close` per response, loopback-only bind.
- **Postgres-only in practice.** MySQL/SQLite produce DDL but have no live driver.
- **No SCRAM or TLS.** Modern default Postgres auth (`scram-sha-256`) isn't
  supported yet; use `trust`/`md5`. No TLS on the HTTP server or the DB connection.
- **No sessions, cookies, CSRF, or auth guards** (the `.ward` in the sample is a
  TODO).
- **Templates lack inheritance/includes/macros** and re-parse on every render.

A full backlog with fix guides lives alongside this project. Contributions toward
any of the above are the most useful place to start.

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