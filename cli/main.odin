package main

// gjallarhorn CLI — project scaffolding, in the spirit of `nest generate`.
//
// Build once, then run from your project root (the dir holding gjallarhorn/ and
// your resource packages):
//
//     odin build cli -out:gh
//     ./gh generate resource users      # or: ./gh g resource users
//
// or without building:
//
//     odin run cli -- generate resource users
//
// `generate resource <name>` scaffolds a package <name>/ with model.odin,
// controller.odin, and routes.odin — a full CRUD resource wired to Mímir (the
// ORM) and the router, mirroring ./sample. The struct is the singular of <name>
// (users -> User), so Mímir's table name comes out as <name>.

import "core:fmt"
import "core:os"
import "core:strings"

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
		os.exit(1)
	}
	switch args[0] {
	case "new":
		if len(args) < 2 {
			fmt.eprintln("usage: gh new <app>")
			os.exit(1)
		}
		os.exit(gen_new(args[1]))
	case "generate", "g":
		if len(args) < 3 {
			fmt.eprintln("usage: gh generate resource <name>")
			os.exit(1)
		}
		switch args[1] {
		case "resource", "res", "r":
			os.exit(gen_resource(args[2]))
		case:
			fmt.eprintfln("unknown generate target %q (supported: resource)", args[1])
			os.exit(1)
		}
	case "bench":
		// Load-test a running Gjallarhorn app. See bench.odin.
		if len(args) < 3 {
			fmt.eprintln("usage: gh bench <load|hold> <url> [-c N] [-d SECONDS] [-close]")
			os.exit(1)
		}
		os.exit(run_bench(args[1:]))
	case "run":
		// Build + run the app in the current directory: `odin run .` with any extra
		// flags forwarded. Replaces this process with the compiler. See run.odin.
		os.exit(run_app(args[1:]))
	case "build":
		// Compile the app in the current directory: `odin build .` with any extra
		// flags forwarded (e.g. -out:app, -o:speed). See run.odin.
		os.exit(build_app(args[1:]))
	case "docs":
		// Browse the framework docs by topic in a terminal UI. See docs.odin.
		os.exit(run_docs(args[1:]))
	case "help", "-h", "--help":
		usage()
	case:
		fmt.eprintfln("unknown command %q", args[0])
		usage()
		os.exit(1)
	}
}

usage :: proc() {
	fmt.println("gjallarhorn CLI")
	fmt.println("")
	fmt.println("Usage:")
	fmt.println("  gh new <app>                  scaffold a new, runnable app (vendors the library)")
	fmt.println("  gh run [flags]                build + run the app here (odin run . [flags])")
	fmt.println("  gh build [flags]              compile the app here (odin build . [flags])")
	fmt.println("  gh generate resource <name>   scaffold a CRUD resource package (alias: g res)")
	fmt.println("  gh bench <load|hold> <url>    load-test a running app (-c N -d SECONDS -close)")
	fmt.println("  gh docs [topic]               browse the framework docs in a terminal UI")
	fmt.println("  gh help                       show this help")
	fmt.println("")
	fmt.println("Examples:")
	fmt.println("  gh new blog                   -> blog/ with main.odin + gjallarhorn/ vendored")
	fmt.println("  gh run                        -> odin run .  (start the app on :8091)")
	fmt.println("  gh generate resource users    -> users/{model,controller,routes}.odin")
	fmt.println("  gh bench load http://127.0.0.1:8091/ -c 50 -d 5")
}

// gen_new scaffolds a new project directory: a minimal, runnable main.odin plus a
// vendored copy of the gjallarhorn library (resolved via library_source, so it
// works both from a checkout and from a system install), so that
// `cd <app> && odin run .` works immediately.
gen_new :: proc(name: string) -> int {
	if !valid_project(name) {
		fmt.eprintfln("invalid app name %q: use letters, digits, '_' or '-'", name)
		return 1
	}
	if os.exists(name) {
		fmt.eprintfln("%q already exists", name)
		return 1
	}
	if err := os.make_directory(name); err != os.ERROR_NONE {
		fmt.eprintfln("could not create %q: %v", name, err)
		return 1
	}

	// Vendor the library so the new project is self-contained. The source is
	// resolved from GJALLARHORN_LIB, then ./gjallarhorn (a checkout), then the
	// system install path the package writes to (see library_source).
	vendored := false
	if src, ok := library_source(); ok {
		dst := strings.concatenate({name, "/gjallarhorn"}, context.temp_allocator)
		if copy_tree(src, dst) {
			vendored = true
			fmt.printfln("  vendored gjallarhorn/ (from %s)", src)
		} else {
			fmt.eprintln("  warning: could not fully vendor gjallarhorn/")
		}
	}

	files := [][2]string {
		{"main.odin", render_project(MAIN_APP_TMPL, name)},
		{"docker-compose.yml", render_project(COMPOSE_TMPL, name)},
		{".gitignore", render_project(GITIGNORE_TMPL, name)},
	}
	for f in files {
		path := strings.concatenate({name, "/", f[0]}, context.temp_allocator)
		if err := os.write_entire_file_from_string(path, f[1]); err != os.ERROR_NONE {
			fmt.eprintfln("could not write %s: %v", path, err)
			return 1
		}
		fmt.printfln("  created %s", path)
	}

	fmt.println("")
	fmt.printfln("Created app %q. Run it:", name)
	fmt.printfln("    cd %s && odin run .", name)
	fmt.println("    # -> http://127.0.0.1:8091/hello/world")
	if !vendored {
		fmt.println("")
		fmt.println("NOTE: could not find the framework to vendor. Set GJALLARHORN_LIB to the")
		fmt.printfln("      gjallarhorn package dir, or copy it into %s/gjallarhorn manually.", name)
	}
	fmt.println("")
	fmt.println("Add a CRUD resource with:  gh generate resource <name>")
	return 0
}

// library_source resolves the gjallarhorn library package directory to vendor
// from, so `new` works both from a checkout and when installed as a package. It
// checks, in order: the GJALLARHORN_LIB env var, ./gjallarhorn (a checkout or an
// existing project), then /usr/share/gjallarhorn/gjallarhorn (the install path
// the AUR package writes to).
library_source :: proc() -> (string, bool) {
	if v, found := os.lookup_env("GJALLARHORN_LIB", context.temp_allocator); found && is_library_dir(v) {
		return v, true
	}
	for c in ([]string{"gjallarhorn", "/usr/share/gjallarhorn/gjallarhorn"}) {
		if is_library_dir(c) {
			return c, true
		}
	}
	return "", false
}

// is_library_dir reports whether `path` looks like the gjallarhorn package — a
// directory carrying a marker source file — so we never vendor a stray folder.
is_library_dir :: proc(path: string) -> bool {
	if path == "" || !os.is_directory(path) {
		return false
	}
	marker := strings.concatenate({path, "/mimir.odin"}, context.temp_allocator)
	return os.exists(marker)
}

// copy_tree recursively copies the directory `src` into `dst` (created if absent).
copy_tree :: proc(src, dst: string) -> bool {
	os.make_directory(dst) // ignore "already exists"
	f, oerr := os.open(src)
	if oerr != os.ERROR_NONE {
		return false
	}
	defer os.close(f)

	it: os.Read_Directory_Iterator
	os.read_directory_iterator_init(&it, f)
	ok := true
	for fi in os.read_directory_iterator(&it) {
		if fi.name == "." || fi.name == ".." {
			continue
		}
		cs := strings.concatenate({src, "/", fi.name}, context.temp_allocator)
		cd := strings.concatenate({dst, "/", fi.name}, context.temp_allocator)
		#partial switch fi.type {
		case .Directory:
			if !copy_tree(cs, cd) {
				ok = false
			}
		case:
			data, rerr := os.read_entire_file(cs, context.temp_allocator)
			if rerr != os.ERROR_NONE {
				ok = false
				continue
			}
			if os.write_entire_file_from_string(cd, string(data)) != os.ERROR_NONE {
				ok = false
			}
		}
	}
	return ok
}

// valid_project allows a directory-friendly name (identifiers plus '-').
valid_project :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c, i in s {
		is_alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		is_digit := c >= '0' && c <= '9'
		if i == 0 && !is_alpha {
			return false
		}
		if !is_alpha && !is_digit && c != '_' && c != '-' {
			return false
		}
	}
	return true
}

// render_project substitutes the {{name}} placeholder.
render_project :: proc(tmpl, name: string) -> string {
	out, _ := strings.replace_all(tmpl, "{{name}}", name, context.temp_allocator)
	return out
}

// gen_resource scaffolds the <name>/ package. Returns a process exit code.
gen_resource :: proc(name: string) -> int {
	pkg := strings.to_lower(name, context.temp_allocator)
	if !valid_package(pkg) {
		fmt.eprintfln(
			"invalid resource name %q: use letters, digits and underscores, starting with a letter",
			name,
		)
		return 1
	}
	strct := pascal_singular(pkg)
	route := strings.concatenate({"/", pkg}, context.temp_allocator)

	if os.exists(pkg) && os.is_directory(pkg) {
		// Allow adding into an existing dir but never clobber files below.
	} else if os.exists(pkg) {
		fmt.eprintfln("%q already exists and is not a directory", pkg)
		return 1
	} else if err := os.make_directory(pkg); err != os.ERROR_NONE {
		fmt.eprintfln("could not create directory %q: %v", pkg, err)
		return 1
	}

	files := [][2]string {
		{"model.odin", render(MODEL_TMPL, pkg, strct, route)},
		{"controller.odin", render(CONTROLLER_TMPL, pkg, strct, route)},
		{"routes.odin", render(ROUTES_TMPL, pkg, strct, route)},
	}
	for f in files {
		path := strings.concatenate({pkg, "/", f[0]}, context.temp_allocator)
		if os.exists(path) {
			fmt.eprintfln("refusing to overwrite existing %s", path)
			return 1
		}
		if err := os.write_entire_file_from_string(path, f[1]); err != os.ERROR_NONE {
			fmt.eprintfln("could not write %s: %v", path, err)
			return 1
		}
		fmt.printfln("  created %s", path)
	}

	// The generated package imports `../gjallarhorn`; warn (don't fail) if this
	// isn't a project with the framework vendored as a sibling.
	if !is_library_dir("gjallarhorn") {
		fmt.println("")
		fmt.println("  note: no ./gjallarhorn here — run this inside a project created by")
		fmt.println("        `gjallarhorn new`, so the resource's `../gjallarhorn` import resolves.")
	}

	fmt.println("")
	fmt.printfln("Resource %q scaffolded. Wire it into main.odin:", pkg)
	fmt.printfln("    import \"%s\"", pkg)
	fmt.println("    // ...inside main(), after gh.new():")
	fmt.printfln("    %s.register(&app)", pkg)
	fmt.println("")
	fmt.printfln("Then: GET %s/:id  POST %s  PUT %s/:id  DELETE %s/:id", route, route, route, route)
	return 0
}

// valid_package reports whether s is a legal Odin package / identifier name.
valid_package :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c, i in s {
		is_alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		is_digit := c >= '0' && c <= '9'
		if i == 0 && !is_alpha {
			return false
		}
		if !is_alpha && !is_digit && c != '_' {
			return false
		}
	}
	return true
}

// pascal_singular turns a resource name into its model struct name: drop one
// trailing 's' (users -> user), then upper-case the first letter (user -> User).
pascal_singular :: proc(s: string) -> string {
	sing := s
	if len(s) > 1 && strings.has_suffix(s, "s") {
		sing = s[:len(s) - 1]
	}
	b := strings.builder_make(context.temp_allocator)
	for c, i in transmute([]u8)sing {
		if i == 0 && c >= 'a' && c <= 'z' {
			strings.write_byte(&b, c - 32)
		} else {
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// render substitutes the {{pkg}}, {{Struct}} and {{route}} placeholders.
render :: proc(tmpl, pkg, strct, route: string) -> string {
	out := strings.clone(tmpl, context.temp_allocator)
	out, _ = strings.replace_all(out, "{{pkg}}", pkg, context.temp_allocator)
	out, _ = strings.replace_all(out, "{{Struct}}", strct, context.temp_allocator)
	out, _ = strings.replace_all(out, "{{route}}", route, context.temp_allocator)
	return out
}

// ---------------------------------------------------------------------------
// Templates. The model carries `db:` backtick tags, so it's a normal string with
// literal backticks; the others are backtick raw strings.
// ---------------------------------------------------------------------------

MODEL_TMPL :: "package {{pkg}}\n\n" +
	"// {{Struct}} — the \"M\" in MVC. `db:` struct tags drive Mímir, the ORM\n" +
	"// (gjallarhorn/mimir.odin): the column name, then flags. `id` is an\n" +
	"// auto-assigned primary key. Edit these fields to match your domain; the\n" +
	"// table (\"{{pkg}}\") is auto-migrated at run() from register().\n" +
	"{{Struct}} :: struct {\n" +
	"\tid:   int    `db:\"id,pk,auto\"`,\n" +
	"\tname: string `db:\"name,notnull\"`,\n" +
	"}\n"

CONTROLLER_TMPL :: `package {{pkg}}

import "core:fmt"
import "core:strconv"
import gh "../gjallarhorn"

// GET {{route}}/:id — recall one {{Struct}} by id and hydrate it with scan_one.
get_handler :: proc(b: ^gh.Bifrost) {
	id, ok := gh.param_int(b, "id")
	if !ok {
		gh.text(b, 400, "id must be an integer")
		return
	}
	w := gh.well(b)
	q := gh.recall(w, {{Struct}})
	gh.whose(&q, "id = ?", id)
	gh.limit(&q, 1)
	rows, qok := gh.query(w, gh.sql(&q))
	if !qok {
		gh.text(b, 503, "database unavailable")
		return
	}
	row, found := gh.scan_one(rows, {{Struct}})
	if !found {
		gh.not_found(b)
		return
	}
	gh.json(b, 200, row)
}

// POST {{route}} — create a {{Struct}} from a JSON body, e.g. {"name":"thing"}.
create_handler :: proc(b: ^gh.Bifrost) {
	payload: {{Struct}}
	if !gh.bind_json(b, &payload) {
		return // bind_json already wrote the 400
	}
	if payload.name == "" {
		gh.text(b, 400, "name required")
		return
	}
	w := gh.well(b)
	rows, qok := gh.query(w, gh.offer(w, {{Struct}}{name = payload.name}))
	if !qok {
		if gh.failed(rows) {
			gh.text(b, 400, fmt.tprintf("database error %s: %s", rows.err.code, rows.err.message))
		} else {
			gh.text(b, 503, "database unavailable")
		}
		return
	}
	id := 0
	if len(rows.rows) > 0 {
		id, _ = strconv.parse_int(rows.rows[0][0]) // the RETURNING id
	}
	gh.json(b, 201, {{Struct}}{id = id, name = payload.name})
}

// PUT {{route}}/:id — replace a {{Struct}}'s name by id (UPDATE ... WHERE id = $n).
update_handler :: proc(b: ^gh.Bifrost) {
	id, ok := gh.param_int(b, "id")
	if !ok {
		gh.text(b, 400, "id must be an integer")
		return
	}
	payload: {{Struct}}
	if !gh.bind_json(b, &payload) {
		return
	}
	w := gh.well(b)
	rows, qok := gh.query(w, gh.amend(w, {{Struct}}{id = id, name = payload.name}))
	if !qok {
		gh.text(b, 503, "database unavailable")
		return
	}
	gh.json(b, 200, struct {
		updated: string,
	}{updated = rows.tag})
}

// DELETE {{route}}/:id — remove a {{Struct}} by id (DELETE FROM ... WHERE id = $1).
delete_handler :: proc(b: ^gh.Bifrost) {
	id, ok := gh.param_int(b, "id")
	if !ok {
		gh.text(b, 400, "id must be an integer")
		return
	}
	w := gh.well(b)
	rows, qok := gh.query(w, gh.forget(w, {{Struct}}{id = id}))
	if !qok {
		gh.text(b, 503, "database unavailable")
		return
	}
	gh.json(b, 200, struct {
		deleted: string,
	}{deleted = rows.tag})
}
`

ROUTES_TMPL :: `package {{pkg}}

import gh "../gjallarhorn"

// register hands {{Struct}}'s model to Mímir (auto-migrated at run()) and wires
// its CRUD routes. Call it from main.odin:
//     import "{{pkg}}"
//     {{pkg}}.register(&app)
register :: proc(app: ^gh.App) {
	gh.remember(app, {{Struct}})

	gh.get(app, "{{route}}/:id", get_handler)
	gh.post(app, "{{route}}", create_handler)
	gh.put(app, "{{route}}/:id", update_handler)
	gh.delete(app, "{{route}}/:id", delete_handler)
}
`

// ---------------------------------------------------------------------------
// `new` project templates.
// ---------------------------------------------------------------------------

MAIN_APP_TMPL :: `package main

import gh "gjallarhorn"

// A minimal Gjallarhorn app. Add database-backed CRUD with the CLI:
//     gh generate resource users
// then register it in main() (see the commented line below).

hello :: proc(b: ^gh.Bifrost) {
	name, ok := gh.param(b, "name")
	if !ok {
		name = "world"
	}
	gh.json(b, 200, struct {
		hello: string,
	}{hello = name})
}

main :: proc() {
	app := gh.new(gh.Config{
		port = 8091,
		// Sessions/CSRF are HMAC-signed with this key. CHANGE IT before shipping —
		// release builds refuse to start on the insecure default.
		secret = "{{name}}-dev-secret-change-me",

		// Uncomment to connect the ORM (run: docker compose up -d):
		// db_type  = .Postgres,
		// postgres = gh.Postgres_Config{
		// 	host = "127.0.0.1", port = 5432,
		// 	user = "app", password = "secret", dbname = "{{name}}",
		// },
	})

	// Middleware ("runes"), registered onion-style, outermost first.
	gh.rune(&app, gh.logger)
	gh.rune(&app, gh.cors)

	gh.get(&app, "/hello/:name", hello)

	// Generated resources register here, e.g.:
	//     users.register(&app)

	gh.run(&app)
}
`

COMPOSE_TMPL :: `# docker-compose.yml — a local Postgres for Mímir (the ORM).
# Usage: docker compose up -d   (then uncomment the postgres block in main.odin)

services:
  db:
    image: postgres:16-alpine
    container_name: {{name}}-db
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: {{name}}
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app -d {{name}}"]
      interval: 2s
      timeout: 3s
      retries: 20
`

GITIGNORE_TMPL :: `# build artifacts
/{{name}}
/gh
*.bin
`
