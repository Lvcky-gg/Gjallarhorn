package main

// bench.odin — `gjallarhorn bench`, a small self-contained HTTP load generator
// (no deps, same ethos as the framework). It answers one architectural question
// with numbers: the server is a *bounded thread pool*, not an event loop — where
// does it saturate, and do slow keep-alive clients cause head-of-line blocking?
//
//   gjallarhorn bench load http://127.0.0.1:8091/ -c 50 -d 5        # throughput
//   gjallarhorn bench load ... -c 50 -d 5 -close                    # no keep-alive
//   gjallarhorn bench hold http://127.0.0.1:8091/ -c 60 -d 12       # pin N workers idle
//
// `load` fires requests from `-c` concurrent connections for `-d` seconds and
// reports req/s and latency percentiles. `hold` opens `-c` keep-alive
// connections, makes one request each, then holds them idle — occupying that many
// server workers — so a `load` run alongside it measures the blocking.

import "core:fmt"
import "core:net"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

Bench_Config :: struct {
	host:       string,
	port:       int,
	path:       string,
	keep_alive: bool,
	deadline:   time.Tick,
}

Bench_Result :: struct {
	latencies: [dynamic]f64, // milliseconds, per successful request
	ok:        int,
	errors:    int,
	bytes:     i64,
}

Bench_Job :: struct {
	cfg: Bench_Config,
	res: ^Bench_Result,
}

// run_bench is the `bench` subcommand: args are e.g. {"load", "http://…", "-c", "50"}.
run_bench :: proc(args: []string) -> int {
	cmd, url := args[0], args[1]
	host, port, path, url_ok := parse_url(url)
	if !url_ok {
		fmt.eprintfln("bad url %q (want http://host:port/path)", url)
		return 1
	}

	conc, dur, keep_alive := 50, 5, true
	for i := 2; i < len(args); i += 1 {
		switch args[i] {
		case "-c":
			i += 1;if i < len(args) {conc, _ = strconv.parse_int(args[i])}
		case "-d":
			i += 1;if i < len(args) {dur, _ = strconv.parse_int(args[i])}
		case "-close":
			keep_alive = false
		case "-keepalive":
			keep_alive = true
		}
	}
	if conc < 1 {conc = 1}

	cfg := Bench_Config {
		host       = host,
		port       = port,
		path       = path,
		keep_alive = keep_alive,
		deadline   = time.tick_add(time.tick_now(), time.Duration(dur) * time.Second),
	}
	switch cmd {
	case "load":
		bench_run_load(cfg, conc, dur)
	case "hold":
		bench_run_hold(cfg, conc, dur)
	case:
		fmt.eprintln("usage: gjallarhorn bench <load|hold> <url> [-c N] [-d SECONDS] [-close]")
		return 1
	}
	return 0
}

// bench_run_load drives `conc` connections against the target for the duration
// and prints a summary plus one machine-readable SUMMARY line for scripting.
bench_run_load :: proc(cfg: Bench_Config, conc, dur: int) {
	results := make([]Bench_Result, conc)
	jobs := make([]Bench_Job, conc)
	threads := make([]^thread.Thread, conc)

	start := time.tick_now()
	for i in 0 ..< conc {
		results[i].latencies = make([dynamic]f64, 0, 4096)
		jobs[i] = Bench_Job{cfg, &results[i]}
		threads[i] = thread.create_and_start_with_poly_data(&jobs[i], bench_load_worker, self_cleanup = false)
	}
	for tptr in threads {
		thread.join(tptr)
		thread.destroy(tptr)
	}
	elapsed := time.duration_seconds(time.tick_diff(start, time.tick_now()))

	all := make([dynamic]f64, 0, 1 << 16)
	total_ok, total_err: int
	total_bytes: i64
	for &r in results {
		append(&all, ..r.latencies[:])
		total_ok += r.ok
		total_err += r.errors
		total_bytes += r.bytes
	}
	slice.sort(all[:])

	rps := elapsed > 0 ? f64(total_ok) / elapsed : 0
	mbps := elapsed > 0 ? f64(total_bytes) / elapsed / (1024 * 1024) : 0

	fmt.printfln("\n%s  (c=%d, keepalive=%v, %.1fs)", cfg.path, conc, cfg.keep_alive, elapsed)
	fmt.printfln("  requests : %d ok, %d errors", total_ok, total_err)
	fmt.printfln("  throughput: %.0f req/s   %.1f MiB/s", rps, mbps)
	if len(all) > 0 {
		fmt.printfln(
			"  latency ms: p50 %.2f  p90 %.2f  p99 %.2f   (min %.2f, mean %.2f, max %.2f)",
			bench_pct(all[:], 50),
			bench_pct(all[:], 90),
			bench_pct(all[:], 99),
			all[0],
			bench_mean(all[:]),
			all[len(all) - 1],
		)
	}
	fmt.printfln(
		"SUMMARY c=%d keepalive=%v rps=%.0f p50=%.2f p99=%.2f errors=%d",
		conc,
		cfg.keep_alive,
		rps,
		len(all) > 0 ? bench_pct(all[:], 50) : 0,
		len(all) > 0 ? bench_pct(all[:], 99) : 0,
		total_err,
	)
}

// bench_run_hold opens `conc` keep-alive connections, makes one request on each,
// then holds them idle for the duration — pinning that many server workers.
bench_run_hold :: proc(cfg: Bench_Config, conc, dur: int) {
	pinned: int
	jobs := make([]Bench_Job, conc)
	results := make([]Bench_Result, conc)
	threads := make([]^thread.Thread, conc)
	for i in 0 ..< conc {
		jobs[i] = Bench_Job{cfg, &results[i]}
		threads[i] = thread.create_and_start_with_poly_data(&jobs[i], bench_hold_worker, self_cleanup = false)
	}
	for tptr, i in threads {
		thread.join(tptr)
		thread.destroy(tptr)
		pinned += results[i].ok
	}
	fmt.printfln("held %d/%d connections for %ds", pinned, conc, dur)
}

bench_load_worker :: proc(job: ^Bench_Job) {
	cfg := job.cfg
	buf := make([]u8, 256 * 1024)
	req := transmute([]u8)bench_build_request(cfg.host, cfg.path, cfg.keep_alive)

	sock: net.TCP_Socket
	live := false
	defer if live {net.close(sock)}

	for time.tick_diff(time.tick_now(), cfg.deadline) > 0 {
		if !live {
			s, ok := bench_dial(cfg)
			if !ok {job.res.errors += 1;continue}
			sock, live = s, true
		}
		t0 := time.tick_now()
		if !bench_send_all(sock, req) {job.res.errors += 1;net.close(sock);live = false;continue}
		n, ok := bench_read_response(sock, buf)
		if !ok {job.res.errors += 1;net.close(sock);live = false;continue}
		append(&job.res.latencies, time.duration_milliseconds(time.tick_diff(t0, time.tick_now())))
		job.res.ok += 1
		job.res.bytes += i64(n)
		if !cfg.keep_alive {net.close(sock);live = false}
	}
}

bench_hold_worker :: proc(job: ^Bench_Job) {
	cfg := job.cfg
	buf := make([]u8, 64 * 1024)
	req := transmute([]u8)bench_build_request(cfg.host, cfg.path, true)

	sock, ok := bench_dial(cfg)
	if !ok {return}
	defer net.close(sock)
	if !bench_send_all(sock, req) {return}
	if _, rok := bench_read_response(sock, buf); !rok {return}
	job.res.ok = 1 // pinned one worker

	for time.tick_diff(time.tick_now(), cfg.deadline) > 0 {
		time.sleep(200 * time.Millisecond)
	}
}

// --- minimal HTTP client ---------------------------------------------------

bench_dial :: proc(cfg: Bench_Config) -> (net.TCP_Socket, bool) {
	s, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = cfg.port})
	return s, err == nil
}

bench_build_request :: proc(host, path: string, keep_alive: bool) -> string {
	return fmt.aprintf(
		"GET %s HTTP/1.1\r\nHost: %s\r\nConnection: %s\r\nAccept-Encoding: identity\r\n\r\n",
		path,
		host,
		keep_alive ? "keep-alive" : "close",
	)
}

bench_send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil || n == 0 {
			return false
		}
		sent += n
	}
	return true
}

// bench_read_response consumes exactly one HTTP response (headers +
// Content-Length body) so a keep-alive connection is left at the next one.
bench_read_response :: proc(sock: net.TCP_Socket, buf: []u8) -> (int, bool) {
	total := 0
	header_end := -1
	for header_end < 0 {
		if total >= len(buf) {
			return total, false
		}
		n, err := net.recv_tcp(sock, buf[total:])
		if err != nil || n == 0 {
			return total, false
		}
		total += n
		header_end = strings.index(string(buf[:total]), "\r\n\r\n")
	}
	need := header_end + 4 + bench_content_length(string(buf[:header_end]))
	for total < need {
		if total >= len(buf) {
			return total, false
		}
		n, err := net.recv_tcp(sock, buf[total:])
		if err != nil || n == 0 {
			return total, false
		}
		total += n
	}
	return total, true
}

bench_content_length :: proc(headers: string) -> int {
	for line in strings.split(headers, "\r\n", context.temp_allocator) {
		if c := strings.index_byte(line, ':'); c >= 0 {
			if strings.equal_fold(strings.trim_space(line[:c]), "content-length") {
				n, _ := strconv.parse_int(strings.trim_space(line[c + 1:]))
				return n
			}
		}
	}
	return 0
}

// --- stats + url -----------------------------------------------------------

bench_pct :: proc(sorted: []f64, p: int) -> f64 {
	if len(sorted) == 0 {
		return 0
	}
	return sorted[(p * (len(sorted) - 1)) / 100]
}

bench_mean :: proc(xs: []f64) -> f64 {
	if len(xs) == 0 {
		return 0
	}
	sum: f64
	for x in xs {sum += x}
	return sum / f64(len(xs))
}

parse_url :: proc(url: string) -> (host: string, port: int, path: string, ok: bool) {
	s := url
	if strings.has_prefix(s, "http://") {
		s = s[7:]
	}
	path = "/"
	if slash := strings.index_byte(s, '/'); slash >= 0 {
		path = s[slash:]
		s = s[:slash]
	}
	host, port = s, 80
	if colon := strings.index_byte(s, ':'); colon >= 0 {
		host = s[:colon]
		port, _ = strconv.parse_int(s[colon + 1:])
	}
	return host, port, path, host != "" && port > 0
}
