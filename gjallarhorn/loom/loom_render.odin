package loom

import "core:os"
import "core:strings"

// Render_Ctx carries state that spans a whole render pass. `blocks` maps a block
// name to the nodes that should render for it — an override from a child template
// when one exists, otherwise the base block's own default body (see resolve).
// `dir` is the directory {% include %} resolves partials against; `depth` guards
// against runaway include recursion.
Render_Ctx :: struct {
	blocks: map[string][dynamic]Node,
	dir:    string,
	depth:  int,
}

render_nodes :: proc(sb: ^strings.Builder, nodes: [dynamic]Node, ctx: ^Warp, rc: ^Render_Ctx) -> Loom_Error {
	for n in nodes {
		switch n.kind {
		case .Text:
			strings.write_string(sb, n.text)
		case .Output:
			render_output(sb, n.text, ctx)
		case .If:
			branch := truthy(eval(n.text, ctx).val) ? n.body : n.alt
			if e := render_nodes(sb, branch, ctx, rc); e != .None {
				return e
			}
		case .For:
			if e := render_for(sb, n, ctx, rc); e != .None {
				return e
			}
		case .Block:
			body, ok := rc.blocks[n.text]
			if !ok {
				body = n.body // no entry (e.g. weave without inheritance) -> default
			}
			if e := render_nodes(sb, body, ctx, rc); e != .None {
				return e
			}
		case .Extends:
			// Resolved before rendering; nothing to emit here.
		case .Include:
			if e := render_include(sb, n.text, ctx, rc); e != .None {
				return e
			}
		}
	}
	return .None
}

// render_include pulls in another template at render time and renders it against
// the current context. The partial resolves its own {% extends %} chain and may
// include further partials, so it gets a fresh block map but inherits `dir`. The
// path is traversal-clamped (safe_path), matching the static mounts.
render_include :: proc(sb: ^strings.Builder, name: string, ctx: ^Warp, rc: ^Render_Ctx) -> Loom_Error {
	if rc.depth >= MAX_INCLUDE_DEPTH {
		return .Include_Too_Deep
	}
	path, ok := safe_path(rc.dir, name)
	if !ok {
		return .Forbidden_Path
	}
	nodes, lerr := load_template(path)
	if lerr != .None {
		return lerr
	}

	sub_blocks := make(map[string][dynamic]Node, context.temp_allocator)
	root, err := resolve_chain(nodes, rc.dir, &sub_blocks)
	if err != .None {
		return err
	}
	sub := Render_Ctx {
		blocks = sub_blocks,
		dir    = rc.dir,
		depth  = rc.depth + 1,
	}
	return render_nodes(sb, root, ctx, &sub)
}


render_output :: proc(sb: ^strings.Builder, expr: string, ctx: ^Warp) {
	e := eval(expr, ctx)
	s := to_text(e.val)
	if e.safe {
		strings.write_string(sb, s)
	} else {
		strings.write_string(sb, html_escape(s, context.temp_allocator))
	}
}

render_for :: proc(sb: ^strings.Builder, n: Node, ctx: ^Warp, rc: ^Render_Ctx) -> Loom_Error {
	v := eval(n.iter, ctx).val
	arr, ok := v.([]Value)
	if !ok || len(arr) == 0 {
		return render_nodes(sb, n.alt, ctx, rc) // empty -> the {% else %} body
	}

	old_item, had_item := (ctx^)[n.ivar]
	old_loop, had_loop := (ctx^)["loop"]
	for item, i in arr {
		(ctx^)[n.ivar] = item

		lm := make(map[string]Value, context.temp_allocator)
		lm["index0"] = i
		lm["index"] = i + 1
		lm["first"] = i == 0
		lm["last"] = i == len(arr) - 1
		lm["length"] = len(arr)
		(ctx^)["loop"] = lm

		if e := render_nodes(sb, n.body, ctx, rc); e != .None {
			return e
		}
	}

	if had_item {(ctx^)[n.ivar] = old_item} else {delete_key(ctx, n.ivar)}
	if had_loop {(ctx^)["loop"] = old_loop} else {delete_key(ctx, "loop")}
	return .None
}
