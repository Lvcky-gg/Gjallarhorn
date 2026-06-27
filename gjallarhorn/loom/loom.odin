package loom

// loom.odin — Loom, the templating engine. In the myths the Norns sit at the
// well of Urðr and weave the threads of fate; so here a template is the warp
// already strung on the loom, and `weave` runs the weft of your data through
// it to produce the finished cloth (HTML).
//
// The dialect is Jinja's, pared to its load-bearing parts:
//
//   {{ expr }}              output an expression (HTML-escaped by default)
//   {{ expr | filter }}     run it through a filter pipeline (upper, default…)
//   {% if c %}…{% elif %}…{% else %}…{% endif %}   branch
//   {% for x in xs %}…{% else %}…{% endfor %}      iterate (empty -> else)
//   {# … #}                comment, dropped
//
// Inside a `for`, a `loop` binding carries index / index0 / first / last /
// length, as in Jinja.
//
// The security checkpoint for this feature is XSS: output is HTML-escaped
// unless the expression's filter pipeline ends in `| safe` (or `| escape`,
// which escapes then marks safe). Safety rides alongside the value as it is
// evaluated (see Eval), so it is decided per output, not globally.
//
// Phase note, matching the rest of gjallarhorn's incremental honesty: this is
// the expression/statement core plus inheritance ({% extends %} / {% block %})
// and {% include %}. Macros and whitespace-control ({%- -%}) are the next phase.
// Templates read from disk are parsed once and cached by path+mtime (see
// load_template); expressions are still re-parsed each render.
//
// The HTTP glue that wires Loom into gjallarhorn's request/response cycle
// (render, html, mounts) lives back in the parent package; this package is the
// engine on its own, free of any web dependency.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

Value :: union {
	string,
	int,
	f64,
	bool,
	[]Value,
	map[string]Value,
}

Warp :: map[string]Value

// Binding — one key/value thread, the argument shape of `warp`.
Binding :: struct {
	key: string,
	val: Value,
}

Loom_Error :: enum {
	None,
	Unexpected_End,    // a block tag left open ({% if %} with no {% endif %})
	Unknown_Tag,       // a {% … %} whose keyword Loom doesn't know
	Bad_Syntax,        // e.g. {% for %} without "x in xs"
	Missing_Template,  // {% extends/include "x" %} where x can't be read from dir
	Forbidden_Path,    // a referenced template would escape the mount dir
	Include_Too_Deep,  // {% include %} nested past MAX_INCLUDE_DEPTH (likely a cycle)
}

// Guards runaway / cyclic {% include %} chains from blowing the stack. Templates
// are author-trusted, so this is a safety net, not a security boundary.
MAX_INCLUDE_DEPTH :: 64

warp :: proc(bindings: ..Binding, allocator := context.allocator) -> Warp {
	m := make(Warp, len(bindings), allocator)
	for b in bindings {
		m[b.key] = b.val
	}
	return m
}

list :: proc(vals: ..Value, allocator := context.allocator) -> []Value {
	out := make([]Value, len(vals), allocator)
	copy(out, vals)
	return out
}


// weave renders an in-memory template `src` against `ctx`. `dir` is the directory
// {% extends %} / {% include %} names resolve against; leave it "" for a
// self-contained template. The root `src` here is parsed fresh every call (it
// has no path to key a cache on) — for the hot path of serving a file, prefer
// weave_file, which caches.
weave :: proc(src: string, ctx: Warp, allocator := context.allocator, dir := "") -> (string, Loom_Error) {
	nodes, err := parse_src(src, context.temp_allocator)
	if err != .None {
		return "", err
	}
	return weave_nodes(nodes, ctx, dir, allocator)
}

// weave_file renders the template at `path` against `ctx`. The parsed tree is
// cached by path+mtime (load_template), as are any bases/partials it pulls in,
// so a hot template is lexed and parsed only once per file revision. Bases and
// includes resolve against `path`'s own directory.
weave_file :: proc(path: string, ctx: Warp, allocator := context.allocator) -> (string, Loom_Error) {
	nodes, err := load_template(path)
	if err != .None {
		return "", err
	}
	return weave_nodes(nodes, ctx, filepath.dir(path), allocator)
}

// weave_nodes is the shared tail of weave / weave_file: resolve the {% extends %}
// chain over an already-parsed root, then render. `nodes` is not mutated.
weave_nodes :: proc(nodes: [dynamic]Node, ctx: Warp, dir: string, allocator: runtime.Allocator) -> (string, Loom_Error) {
	rc := Render_Ctx {
		blocks = make(map[string][dynamic]Node, context.temp_allocator),
		dir    = dir,
	}
	root, err := resolve_chain(nodes, dir, &rc.blocks)
	if err != .None {
		return "", err
	}

	local := ctx // a header copy we may add scratch bindings (loop, loop vars) to
	sb := strings.builder_make(allocator)
	if rerr := render_nodes(&sb, root, &local, &rc); rerr != .None {
		return strings.to_string(sb), rerr
	}
	return strings.to_string(sb), .None
}

// parse_src lexes and parses `src` into a node tree allocated with `allocator`.
// Node `text` fields are slices into `src`, so `src` must outlive the tree (the
// cache keeps both; weave's in-memory root uses the temp allocator for both).
parse_src :: proc(src: string, allocator: runtime.Allocator) -> ([dynamic]Node, Loom_Error) {
	context.allocator = allocator // parse_block builds its node arrays here
	toks := lex(src, context.temp_allocator)
	p := Parser{toks = toks[:], pos = 0}
	nodes, _, err := parse_block(&p, nil)
	if err != .None {
		return nil, err
	}
	return nodes, .None
}

// resolve_chain walks the {% extends %} chain from an already-parsed root: it
// returns the node tree to actually render — the last template with no
// {% extends %} of its own — and fills `blocks` with the winning body for every
// block name. More-derived templates are visited first and registered first, and
// registration never overwrites, so a child's block wins (collect_blocks).
resolve_chain :: proc(nodes: [dynamic]Node, dir: string, blocks: ^map[string][dynamic]Node) -> ([dynamic]Node, Loom_Error) {
	collect_blocks(nodes, blocks)

	base, extends := extends_target(nodes)
	if !extends {
		return nodes, .None
	}

	path, ok := safe_path(dir, base)
	if !ok {
		return nil, .Forbidden_Path
	}
	base_nodes, err := load_template(path)
	if err != .None {
		return nil, err
	}
	return resolve_chain(base_nodes, dir, blocks)
}

// ---------------------------------------------------------------------------
// Compiled-node cache
//
// Parsing is the per-render cost the file flagged as the optimisation seam.
// load_template parses a file once and reuses the tree until the file's mtime
// changes. Workers run one-per-connection (see server.odin), so the map is
// mutex-guarded; entries and their backing strings/nodes live on the process
// heap. A stale entry is replaced, never freed: another worker may still be
// rendering the old tree, so orphaning it (a tiny, rare leak on file change)
// beats risking a use-after-free.
// ---------------------------------------------------------------------------

Cache_Entry :: struct {
	mtime: time.Time,
	src:   string, // owned; nodes slice into it
	nodes: [dynamic]Node, // owned, heap-allocated
}

Template_Cache :: struct {
	mu:      sync.Mutex,
	entries: map[string]Cache_Entry,
	parses:  map[string]int, // parses-from-disk per path (cache misses); for tests
}

@(private)
cache: Template_Cache

// loaded_parse_count reports how many times load_template has parsed `path` from
// disk — i.e. cache misses for that file. It stays flat across cache hits, so a
// test can prove a hot template is parsed once. Per-path (not global) so it's
// stable when the test suite runs templates in parallel.
loaded_parse_count :: proc(path: string) -> int {
	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)
	return cache.parses[path]
}

load_template :: proc(path: string) -> ([dynamic]Node, Loom_Error) {
	mtime, terr := os.modification_time_by_path(path)
	if terr != nil {
		return nil, .Missing_Template
	}

	sync.mutex_lock(&cache.mu)
	defer sync.mutex_unlock(&cache.mu)

	if cache.entries == nil {
		cache.entries = make(map[string]Cache_Entry, 16, os.heap_allocator())
		cache.parses = make(map[string]int, 16, os.heap_allocator())
	}
	if e, ok := cache.entries[path]; ok && e.mtime == mtime {
		return e.nodes, .None
	}

	data, ferr := os.read_entire_file(path, os.heap_allocator())
	if ferr != nil {
		return nil, .Missing_Template
	}
	src := string(data)
	nodes, perr := parse_src(src, os.heap_allocator())
	if perr != .None {
		delete(data, os.heap_allocator()) // don't cache a parse failure
		return nil, perr
	}

	entry := Cache_Entry{mtime = mtime, src = src, nodes = nodes}
	if _, exists := cache.entries[path]; exists {
		cache.entries[path] = entry // key already owned; old src/nodes orphaned
		cache.parses[path] += 1
	} else {
		key := strings.clone(path, os.heap_allocator())
		cache.entries[key] = entry
		cache.parses[key] = 1
	}
	return nodes, .None
}

// safe_path joins a template-referenced name onto `dir` and returns the cleaned
// path, refusing (ok=false) anything that would escape `dir`. This is the same
// clean-join-clean-contain traversal clamp the static mounts use over in
// static.odin (safe_target / within_root); the loom package can't import that
// one without a cycle, so it carries its own copy.
safe_path :: proc(dir, name: string) -> (path: string, ok: bool) {
	root, _ := filepath.clean(dir, context.temp_allocator)
	joined, _ := filepath.join({root, name}, context.temp_allocator)
	path, _ = filepath.clean(joined, context.temp_allocator)
	if path == root {
		return path, true
	}
	ok = strings.has_prefix(path, strings.concatenate({root, "/"}, context.temp_allocator))
	return
}

// collect_blocks records each block's body under its name, descending into
// container bodies so nested blocks are reachable. The first body seen for a
// name wins (callers visit child before base), so overrides take precedence.
collect_blocks :: proc(nodes: [dynamic]Node, blocks: ^map[string][dynamic]Node) {
	for n in nodes {
		#partial switch n.kind {
		case .Block:
			if _, seen := blocks[n.text]; !seen {
				blocks[n.text] = n.body
			}
			collect_blocks(n.body, blocks)
		case .If:
			collect_blocks(n.body, blocks)
			collect_blocks(n.alt, blocks)
		case .For:
			collect_blocks(n.body, blocks)
			collect_blocks(n.alt, blocks)
		}
	}
}

extends_target :: proc(nodes: [dynamic]Node) -> (string, bool) {
	for n in nodes {
		if n.kind == .Extends {
			return n.text, true
		}
	}
	return "", false
}
