package main

// run.odin — `gjallarhorn run` and `gjallarhorn build`, convenience wrappers for
// `odin run .` / `odin build .` in the current directory, with any extra flags
// forwarded, e.g.:
//
//   gjallarhorn run                        // odin run .
//   gjallarhorn run -define:GJ_TLS=true    // odin run . -define:GJ_TLS=true
//   gjallarhorn build -out:app             // odin build . -out:app
//   gjallarhorn build -o:speed             // odin build . -o:speed
//
// They replace this process with the compiler (execvp), so stdin/stdout/stderr are
// inherited and — for `run` — Ctrl-C (SIGINT) / SIGTERM reach the running server
// directly, so the bounded worker pool drains and exits cleanly, exactly as if you
// had typed `odin run .` yourself.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// run_app execs `odin run .` with `extra` forwarded.
run_app :: proc(extra: []string) -> int {
	return odin_passthrough("run", "run", extra)
}

// build_app execs `odin build .` with `extra` forwarded.
build_app :: proc(extra: []string) -> int {
	return odin_passthrough("build", "build", extra)
}

// odin_passthrough replaces this process with `odin <verb> . <extra...>`. It
// returns only if the exec fails (e.g. the Odin compiler isn't on PATH); on
// success the process is replaced and never comes back here. `cmd` is the
// gjallarhorn subcommand name, used only for error messages.
odin_passthrough :: proc(cmd, verb: string, extra: []string) -> int {
	// A light sanity check: run from a project root (a dir with .odin sources).
	if !has_odin_sources(".") {
		fmt.eprintfln("gjallarhorn %s: no .odin files here — run this from your app's root", cmd)
		fmt.eprintln("  (the directory holding main.odin and your gjallarhorn/ package).")
		return 1
	}

	// argv for execvp: odin <verb> . <extra...> NULL
	argv := make([dynamic]cstring, context.temp_allocator)
	append(&argv, cstring("odin"))
	append(&argv, strings.clone_to_cstring(verb, context.temp_allocator))
	append(&argv, cstring("."))
	for a in extra {
		append(&argv, strings.clone_to_cstring(a, context.temp_allocator))
	}
	append(&argv, nil) // execvp wants a NULL-terminated argv

	suffix := len(extra) > 0 ? strings.concatenate({" ", strings.join(extra, " ", context.temp_allocator)}, context.temp_allocator) : ""
	fmt.eprintfln("→ odin %s .%s", verb, suffix)

	posix.execvp("odin", raw_data(argv[:]))

	// Only reached if the exec failed — most likely the compiler isn't installed.
	fmt.eprintfln("gjallarhorn %s: could not exec `odin` — is the Odin compiler on your PATH?", cmd)
	fmt.eprintln("  install it from https://odin-lang.org/docs/install/")
	return 127
}

// has_odin_sources reports whether `dir` contains at least one *.odin file, so we
// fail fast with a clear message instead of letting the compiler error out.
has_odin_sources :: proc(dir: string) -> bool {
	f, err := os.open(dir)
	if err != os.ERROR_NONE {
		return false
	}
	defer os.close(f)
	it: os.Read_Directory_Iterator
	os.read_directory_iterator_init(&it, f)
	for fi in os.read_directory_iterator(&it) {
		if strings.has_suffix(fi.name, ".odin") {
			return true
		}
	}
	return false
}
