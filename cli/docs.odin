package main

// docs.odin — `gjallarhorn docs`, a self-contained terminal UI that browses the
// framework's documentation by topic (Mímir, Loom, the runes, …). No dependencies:
// raw-mode termios + ANSI, the same from-scratch spirit as the rest of Gjallarhorn.
//
//   gjallarhorn docs            open the browser (arrows / j k to move, q to quit)
//   gjallarhorn docs loom       open straight to a topic (prefix match)
//   gjallarhorn docs --plain    dump every topic as plain text (for piping / no TTY)
//
// When stdout isn't a terminal it falls back to the plain dump automatically, so
// `gjallarhorn docs | less` and `… > DOCS.txt` just work.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Terminal size comes from a TIOCGWINSZ ioctl. core:sys/posix has no ioctl, and
// core:sys/linux is Linux-only, so we bind libc's ioctl directly — that keeps the
// docs TUI building on macOS/BSD (Homebrew) as well as Linux. The request constant
// differs by OS.
foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	ioctl :: proc(fd: c.int, request: c.ulong, arg: rawptr) -> c.int ---
}

TIOCGWINSZ :: 0x5413 when ODIN_OS == .Linux else 0x40087468 // Linux vs Darwin/BSD

// Topic is one entry in the table: a name, a one-line tagline, and body lines.
// A body line starting with "# " is a section header; "  " (two spaces) is a code
// / API line; "" is a blank spacer; anything else is prose (word-wrapped).
Topic :: struct {
	name: string,
	tag:  string,
	body: []string,
}

run_docs :: proc(args: []string) -> int {
	// Flags / topic argument.
	plain := false
	want := ""
	for a in args {
		switch a {
		case "--plain", "-p":
			plain = true
		case "-h", "--help":
			fmt.println("gjallarhorn docs [topic] [--plain]")
			fmt.println("  browse the framework docs by topic; q quits, arrows/jk move,")
			fmt.println("  space/b page the detail. --plain dumps everything as text.")
			return 0
		case:
			if len(a) > 0 && a[0] != '-' {
				want = a
			}
		}
	}

	topics := doc_topics()

	// No TTY (piped/redirected) or --plain: dump text and leave.
	if plain || posix.isatty(posix.STDIN_FILENO) != true || posix.isatty(posix.STDOUT_FILENO) != true {
		docs_plain(topics, want)
		return 0
	}

	sel := 0
	if want != "" {
		if i, ok := topic_index(topics, want); ok {
			sel = i
		}
	}
	docs_tui(topics, sel)
	return 0
}

// topic_index finds a topic by case-insensitive prefix of its name.
topic_index :: proc(topics: []Topic, want: string) -> (int, bool) {
	w := strings.to_lower(want, context.temp_allocator)
	for t, i in topics {
		if strings.has_prefix(strings.to_lower(t.name, context.temp_allocator), w) {
			return i, true
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Plain-text fallback
// ---------------------------------------------------------------------------

docs_plain :: proc(topics: []Topic, want: string) {
	only := -1
	if want != "" {
		if i, ok := topic_index(topics, want); ok {
			only = i
		}
	}
	for t, i in topics {
		if only >= 0 && i != only {
			continue
		}
		fmt.printfln("=== %s — %s ===", t.name, t.tag)
		for line in t.body {
			fmt.println(line)
		}
		fmt.println("")
	}
}

// ---------------------------------------------------------------------------
// The TUI
// ---------------------------------------------------------------------------

// Terminal escape helpers.
ESC :: "\x1b"
ALT_ON :: ESC + "[?1049h" + ESC + "[?25l" // alt screen + hide cursor
ALT_OFF :: ESC + "[?25h" + ESC + "[?1049l" // show cursor + leave alt screen

Key :: enum {
	None,
	Up,
	Down,
	PageUp,
	PageDown,
	Home,
	End,
	Quit,
}

docs_tui :: proc(topics: []Topic, start: int) {
	// Raw mode: no echo, no line buffering, no signal generation (we read q / ^C
	// ourselves), no XON/XOFF or CR->NL mangling. Restored on the way out.
	orig: posix.termios
	posix.tcgetattr(posix.STDIN_FILENO, &orig)
	raw := orig
	raw.c_lflag &~= {.ECHO, .ICANON, .ISIG, .IEXTEN}
	raw.c_iflag &~= {.IXON, .ICRNL, .BRKINT, .INPCK, .ISTRIP}
	raw.c_cc[.VMIN] = posix.cc_t(1)
	raw.c_cc[.VTIME] = posix.cc_t(0)
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)
	defer posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &orig)

	os.write_string(os.stdout, ALT_ON)
	defer os.write_string(os.stdout, ALT_OFF)

	sel := start
	detail_off := 0

	for {
		rows, cols := term_size()
		draw_frame(topics, sel, detail_off, rows, cols)

		switch read_key() {
		case .Quit:
			return
		case .Up:
			if sel > 0 {sel -= 1}
			detail_off = 0
		case .Down:
			if sel < len(topics) - 1 {sel += 1}
			detail_off = 0
		case .Home:
			sel = 0
			detail_off = 0
		case .End:
			sel = len(topics) - 1
			detail_off = 0
		case .PageDown:
			detail_off += 1 // scroll the detail pane; render clamps it
		case .PageUp:
			if detail_off > 0 {detail_off -= 1}
		case .None:
		// unrecognized key — redraw
		}
	}
}

// term_size returns the terminal (rows, cols), falling back to a sane default if
// the ioctl fails (e.g. not a real tty). Clamped so the layout math stays valid.
term_size :: proc() -> (rows, cols: int) {
	Winsize :: struct {
		ws_row, ws_col, ws_x, ws_y: u16,
	}
	ws: Winsize
	ioctl(c.int(1), c.ulong(TIOCGWINSZ), rawptr(&ws)) // fd 1 = stdout
	rows = int(ws.ws_row)
	cols = int(ws.ws_col)
	if rows < 10 {rows = 30}
	if cols < 40 {cols = 100}
	return
}

// read_key reads one keystroke, decoding the arrow / page escape sequences.
read_key :: proc() -> Key {
	b, ok := read_byte()
	if !ok {
		return .Quit // stdin closed
	}
	switch b {
	case 'q', 0x03:
		return .Quit // q or Ctrl-C
	case 'j':
		return .Down
	case 'k':
		return .Up
	case 'g':
		return .Home
	case 'G':
		return .End
	case ' ', 'f':
		return .PageDown
	case 'b':
		return .PageUp
	case 0x1b:
		// An escape sequence: ESC [ <final>, or ESC [ <n> ~ for page keys.
		b2, ok2 := read_byte()
		if !ok2 || (b2 != '[' && b2 != 'O') {
			return .None
		}
		b3, ok3 := read_byte()
		if !ok3 {
			return .None
		}
		switch b3 {
		case 'A':
			return .Up
		case 'B':
			return .Down
		case 'H':
			return .Home
		case 'F':
			return .End
		case '5', '6':
			read_byte() // consume the trailing '~'
			return b3 == '5' ? .PageUp : .PageDown
		}
		return .None
	}
	return .None
}

read_byte :: proc() -> (u8, bool) {
	buf: [1]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n <= 0 {
		return 0, false
	}
	return buf[0], true
}

// render draws one full frame: a title bar, the topic list on the left, the
// selected topic's detail on the right, and a footer of key hints.
draw_frame :: proc(topics: []Topic, sel, detail_off, rows, cols: int) {
	sb := strings.builder_make(context.temp_allocator)
	defer free_all(context.temp_allocator)

	strings.write_string(&sb, ESC + "[H") // home

	list_w := 24
	if cols < 70 {list_w = 18}
	right_x := list_w + 3 // after " │ "
	right_w := cols - right_x - 1
	if right_w < 10 {right_w = 10}

	content_top := 2
	content_bottom := rows - 2
	content_h := content_bottom - content_top + 1
	if content_h < 1 {content_h = 1}

	// Title bar (row 1).
	title := fmt.tprintf("  %sᚷ Gjallarhorn%s  documentation", BOLD_MAGENTA, RESET)
	line_out(&sb, title)

	// Underline (row 2 is content top; use row between title and content).
	strings.write_string(&sb, DIM)
	line_out(&sb, strings.repeat("─", cols, context.temp_allocator))
	strings.write_string(&sb, RESET)

	// Pre-wrap the selected topic's detail into display lines.
	detail := wrap_topic(topics[sel], right_w)
	max_off := len(detail) - content_h
	if max_off < 0 {max_off = 0}
	off := clamp(detail_off, 0, max_off)

	// Keep the selected list item visible.
	list_off := 0
	if sel >= content_h {list_off = sel - content_h + 1}

	for r in 0 ..< content_h {
		// Left cell: a topic name.
		li := r + list_off
		left := strings.repeat(" ", list_w, context.temp_allocator)
		if li < len(topics) {
			if li == sel {
				left = fmt.tprintf("%s %s %s", REVERSE, pad_visible(topics[li].name, list_w - 2), RESET)
			} else {
				left = fmt.tprintf(" %s", pad_visible(topics[li].name, list_w - 1))
			}
		}

		// Right cell: a wrapped detail line.
		right := ""
		di := r + off
		if di < len(detail) {
			right = detail[di]
		}

		line_out(&sb, fmt.tprintf(" %s %s│%s %s", left, DIM, RESET, right))
	}

	// Footer.
	strings.write_string(&sb, DIM)
	more := max_off > 0 ? fmt.tprintf("   [%d/%d lines]", off + content_h > len(detail) ? len(detail) : off + content_h, len(detail)) : ""
	line_out(&sb, fmt.tprintf("  ↑/↓ j/k topic · space/b scroll · g/G top/end · q quit%s", more))
	strings.write_string(&sb, RESET)

	strings.write_string(&sb, ESC + "[J") // clear anything below
	os.write_string(os.stdout, strings.to_string(sb))
}

// line_out writes one screen line: clear-to-end-of-line, then CRLF.
line_out :: proc(sb: ^strings.Builder, s: string) {
	strings.write_string(sb, s)
	strings.write_string(sb, ESC + "[K\r\n")
}

// pad_visible truncates an ASCII string to width and right-pads with spaces, so
// list cells align regardless of name length (names are ASCII).
pad_visible :: proc(s: string, width: int) -> string {
	if width <= 0 {
		return ""
	}
	if len(s) >= width {
		return s[:width]
	}
	return strings.concatenate({s, strings.repeat(" ", width - len(s), context.temp_allocator)}, context.temp_allocator)
}

// wrap_topic turns a topic's tagline + body into display lines, word-wrapped to
// `width`, with section headers and code lines styled.
wrap_topic :: proc(t: Topic, width: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, fmt.tprintf("%s%s%s", BOLD_CYAN, t.name, RESET))
	append(&out, fmt.tprintf("%s%s%s", DIM, t.tag, RESET))
	append(&out, "")
	for raw in t.body {
		if raw == "" {
			append(&out, "")
			continue
		}
		if strings.has_prefix(raw, "# ") {
			append(&out, fmt.tprintf("%s%s%s", BOLD_CYAN, raw[2:], RESET))
			continue
		}
		if strings.has_prefix(raw, "  ") {
			// Code / API line — keep verbatim (dim green), clipped to width.
			s := raw
			if len(s) > width {s = s[:width]}
			append(&out, fmt.tprintf("%s%s%s", GREEN, s, RESET))
			continue
		}
		for wl in wrap_words(raw, width) {
			append(&out, wl)
		}
	}
	return out[:]
}

// wrap_words greedily wraps a prose string to `width` on spaces.
wrap_words :: proc(s: string, width: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	line := strings.builder_make(context.temp_allocator)
	for word in strings.split(s, " ", context.temp_allocator) {
		if strings.builder_len(line) == 0 {
			strings.write_string(&line, word)
		} else if strings.builder_len(line) + 1 + len(word) <= width {
			strings.write_byte(&line, ' ')
			strings.write_string(&line, word)
		} else {
			append(&out, strings.clone(strings.to_string(line), context.temp_allocator))
			strings.builder_reset(&line)
			strings.write_string(&line, word)
		}
	}
	if strings.builder_len(line) > 0 {
		append(&out, strings.clone(strings.to_string(line), context.temp_allocator))
	}
	if len(out) == 0 {
		append(&out, "")
	}
	return out[:]
}

// ANSI styles.
RESET :: ESC + "[0m"
DIM :: ESC + "[2m"
REVERSE :: ESC + "[7m"
BOLD_CYAN :: ESC + "[1;36m"
BOLD_MAGENTA :: ESC + "[1;35m"
GREEN :: ESC + "[2;32m"
