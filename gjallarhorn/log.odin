package gjallarhorn

// log.odin — one small leveled, structured logger the whole framework shares.
//
// Two faces, chosen automatically per output stream:
//   * a TTY gets a pretty line — dim clock, a bold colored level badge, and (for
//     request logs) a colored method/status — so a human scanning the terminal
//     spots warnings and errors at a glance;
//   * anything piped (a file, journald, a log shipper) gets the plain, stable
//     "<rfc3339> <LEVEL> <fields>" line, so machine parsing never sees an escape
//     code. Colour also yields to NO_COLOR / TERM=dumb via core:terminal.
//
// Info and below go to stdout; Warn and above to stderr, so warnings survive a
// stdout redirect. log_min_level gates output, so production can silence Debug
// without touching a single call site.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"
import "core:time"

Log_Level :: enum {
	Debug,
	Info,
	Warn,
	Error,
}

// log_min_level drops anything below it. Package-global; set once at startup
// (e.g. gjallarhorn.log_min_level = .Debug) before serving.
log_min_level := Log_Level.Info

log_level_label := [Log_Level]string {
	.Debug = "DEBUG",
	.Info  = "INFO",
	.Warn  = "WARN",
	.Error = "ERROR",
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

ANSI_RESET :: "\e[0m"
ANSI_DIM :: "\e[2m"

// level_sgr is the SGR sequence painting each level's badge (bold + a hue that
// escalates with severity). Debug stays a quiet gray.
@(private = "file")
level_sgr := [Log_Level]string {
	.Debug = "\e[90m", // gray
	.Info  = "\e[1;32m", // bold green
	.Warn  = "\e[1;33m", // bold yellow
	.Error = "\e[1;31m", // bold red
}

// color_stdout / color_stderr record, once at startup, whether each stream is a
// real terminal that wants colour. Computed in an @(init) so the isatty probe
// and the NO_COLOR/TERM check run exactly once, not per log line.
@(private = "file")
color_stdout: bool
@(private = "file")
color_stderr: bool

@(init)
_log_colors_init :: proc "contextless" () {
	context = runtime.default_context()
	color_stdout = terminal.color_enabled && terminal.is_terminal(os.stdout)
	color_stderr = terminal.color_enabled && terminal.is_terminal(os.stderr)
}

// stream_color reports whether the stream a given level writes to (stderr for
// Warn+, stdout otherwise) is a colour-capable terminal. The logger rune uses it
// to decide whether to paint method/status, so its choice matches logf's.
stream_color :: proc(level: Log_Level) -> bool {
	return color_stderr if level >= .Warn else color_stdout
}

// paint wraps s in an SGR sequence when `on`, else returns it untouched — so the
// same call site produces colour on a TTY and clean text in a pipe.
paint :: proc(on: bool, sgr, s: string, allocator := context.temp_allocator) -> string {
	if !on || sgr == "" {
		return s
	}
	return strings.concatenate({sgr, s, ANSI_RESET}, allocator)
}

// status_sgr picks a colour for an HTTP status by class: 2xx green, 3xx cyan,
// 4xx yellow, 5xx bold red. Anything else is left uncoloured.
status_sgr :: proc(status: int) -> string {
	switch {
	case status >= 500:
		return "\e[1;31m"
	case status >= 400:
		return "\e[33m"
	case status >= 300:
		return "\e[36m"
	case status >= 200:
		return "\e[32m"
	}
	return ""
}

// ---------------------------------------------------------------------------

// logf emits one leveled log line, dropping anything below log_min_level. Warn
// and above go to stderr; everything else to stdout. The message is formatted
// in temp memory, so callers on the request path pay no lasting allocation.
logf :: proc(level: Log_Level, format: string, args: ..any) {
	logft(level, "", format, ..args)
}

// logft is logf with a subsystem tag (e.g. "mimir/pg", "tls") rendered as a dim
// [tag] column between the level badge and the message — so a scan of the log
// tells apart the wire client, the TLS layer, and request handling at a glance.
// An empty tag falls back to the plain, columnless form (what request logs use).
logft :: proc(level: Log_Level, sub: string, format: string, args: ..any) {
	if level < log_min_level {
		return
	}
	msg := fmt.tprintf(format, ..args)

	line: string
	if stream_color(level) {
		// Pretty (TTY): dim HH:MM:SS, a bold colored level badge, an optional dim
		// [tag], then the message.
		clock := paint(true, ANSI_DIM, _clock_now())
		badge := paint(true, level_sgr[level], fmt.tprintf("%-5s", log_level_label[level]))
		if sub != "" {
			tag := paint(true, ANSI_DIM, fmt.tprintf("%-10s", fmt.tprintf("[%s]", sub)))
			line = fmt.tprintf("%s %s %s %s", clock, badge, tag, msg)
		} else {
			line = fmt.tprintf("%s %s %s", clock, badge, msg)
		}
	} else {
		// Plain (piped): the stable, greppable rfc3339 form.
		ts, _ := time.time_to_rfc3339(time.now(), allocator = context.temp_allocator)
		if sub != "" {
			line = fmt.tprintf("%s %-5s [%s] %s", ts, log_level_label[level], sub, msg)
		} else {
			line = fmt.tprintf("%s %-5s %s", ts, log_level_label[level], msg)
		}
	}

	if level >= .Warn {
		fmt.eprintln(line)
	} else {
		fmt.println(line)
	}
}

// _clock_now returns just the wall-clock HH:MM:SS, sliced out of the rfc3339
// timestamp — the date is noise on an interactive terminal.
@(private = "file")
_clock_now :: proc() -> string {
	ts, _ := time.time_to_rfc3339(time.now(), allocator = context.temp_allocator)
	if len(ts) >= 19 {
		return ts[11:19]
	}
	return ts
}

// log_level_for_status maps an HTTP status onto a severity: 5xx is Error, 4xx
// is Warn, everything else Info. Used by the logger rune to level per request.
log_level_for_status :: proc(status: int) -> Log_Level {
	switch {
	case status >= 500:
		return .Error
	case status >= 400:
		return .Warn
	case:
		return .Info
	}
}
