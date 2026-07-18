package gjallarhorn

// log.odin — one small leveled, structured logger the whole framework shares.
// A line is: "<rfc3339> <LEVEL> <space-separated key=value fields>". Info and
// below go to stdout; Warn and above to stderr, so warnings survive a stdout
// redirect. log_min_level gates output, so production can silence Debug without
// touching a single call site.

import "core:fmt"
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

// logf emits one leveled log line, dropping anything below log_min_level. Warn
// and above go to stderr; everything else to stdout. The message is formatted
// in temp memory, so callers on the request path pay no lasting allocation.
logf :: proc(level: Log_Level, format: string, args: ..any) {
	if level < log_min_level {
		return
	}
	ts, _ := time.time_to_rfc3339(time.now(), allocator = context.temp_allocator)
	msg := fmt.tprintf(format, ..args)
	line := fmt.tprintf("%s %-5s %s", ts, log_level_label[level], msg)
	if level >= .Warn {
		fmt.eprintln(line)
	} else {
		fmt.println(line)
	}
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
