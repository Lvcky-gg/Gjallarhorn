package gjallarhorn

// observ.odin — two optional observability Runes.
//
//   request_id — tags each request with an id (honoring an inbound
//     X-Request-Id, else minting one), echoes it in the response header, exposes
//     it on the Bifrost (b.request_id), and has the logger print it — so a log
//     line, the response a client saw, and an upstream proxy's trace all line up.
//
//   metrics — counts requests by status class, tracks in-flight and total
//     latency, and serves a Prometheus text exposition at `metrics_path`
//     (default /metrics). Counters are atomic; workers are threads.
//
//   gh.rune(&app, gh.metrics)      // outermost, to time the whole chain
//   gh.rune(&app, gh.request_id)   // before logger, so the id is available
//   gh.rune(&app, gh.logger)

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

// ---------------------------------------------------------------------------
// request_id
// ---------------------------------------------------------------------------

// REQUEST_ID_HEADER is the request/response header the id rides in.
REQUEST_ID_HEADER :: "X-Request-Id"

// request_id assigns each request an id and echoes it. A sane inbound
// X-Request-Id is reused (so a proxy's trace id carries through); otherwise a
// fresh one is minted.
request_id :: proc(b: ^Bifrost, next: Next) {
	id := inbound_request_id(b)
	if id == "" {
		id = new_request_id()
	}
	b.request_id = id
	set_header(b, REQUEST_ID_HEADER, id)
	next(b)
}

// inbound_request_id returns a caller-supplied X-Request-Id if it's safe to
// reuse — non-empty, not overlong, no control bytes — else "".
inbound_request_id :: proc(b: ^Bifrost) -> string {
	v, ok := header(b, "x-request-id")
	if !ok {
		return ""
	}
	v = strings.trim_space(v)
	if v == "" || len(v) > 128 {
		return ""
	}
	for i in 0 ..< len(v) {
		if v[i] < 0x20 || v[i] == 0x7f {
			return "" // control byte — don't reflect it
		}
	}
	return v
}

// new_request_id mints a random 64-bit id as 16 hex chars — compact, log-safe,
// collision-resistant within any realistic tracing window.
new_request_id :: proc() -> string {
	raw: [8]u8
	crypto.rand_bytes(raw[:])
	enc, _ := hex.encode(raw[:], context.temp_allocator)
	return string(enc)
}

// ---------------------------------------------------------------------------
// metrics
// ---------------------------------------------------------------------------

// metrics_path is the URL the metrics rune serves its exposition at.
metrics_path := "/metrics"

@(private) _m_total: u64
@(private) _m_2xx: u64
@(private) _m_3xx: u64
@(private) _m_4xx: u64
@(private) _m_5xx: u64
@(private) _m_in_flight: i64
@(private) _m_dur_us: u64 // summed request duration, microseconds

// metrics counts every request and serves the exposition at metrics_path. Scrapes
// of that path short-circuit (they aren't counted, and skip the inner chain), so
// monitoring doesn't pollute its own numbers.
metrics :: proc(b: ^Bifrost, next: Next) {
	if b.path == metrics_path {
		write_metrics(b)
		return
	}
	sync.atomic_add(&_m_in_flight, 1)
	start := time.tick_now()
	next(b)
	dur := time.tick_diff(start, time.tick_now())

	sync.atomic_add(&_m_in_flight, -1)
	sync.atomic_add(&_m_total, 1)
	sync.atomic_add(&_m_dur_us, u64(time.duration_microseconds(dur)))
	switch b.status / 100 {
	case 2:
		sync.atomic_add(&_m_2xx, 1)
	case 3:
		sync.atomic_add(&_m_3xx, 1)
	case 4:
		sync.atomic_add(&_m_4xx, 1)
	case 5:
		sync.atomic_add(&_m_5xx, 1)
	}
}

// write_metrics emits the Prometheus text exposition (version 0.0.4).
write_metrics :: proc(b: ^Bifrost) {
	c2 := sync.atomic_load(&_m_2xx)
	c3 := sync.atomic_load(&_m_3xx)
	c4 := sync.atomic_load(&_m_4xx)
	c5 := sync.atomic_load(&_m_5xx)
	total := sync.atomic_load(&_m_total)
	in_flight := sync.atomic_load(&_m_in_flight)
	dur_s := f64(sync.atomic_load(&_m_dur_us)) / 1_000_000

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "# HELP gjallarhorn_requests_total HTTP requests handled, by status class.\n")
	strings.write_string(&sb, "# TYPE gjallarhorn_requests_total counter\n")
	fmt.sbprintf(&sb, "gjallarhorn_requests_total{{status=\"2xx\"}} %d\n", c2)
	fmt.sbprintf(&sb, "gjallarhorn_requests_total{{status=\"3xx\"}} %d\n", c3)
	fmt.sbprintf(&sb, "gjallarhorn_requests_total{{status=\"4xx\"}} %d\n", c4)
	fmt.sbprintf(&sb, "gjallarhorn_requests_total{{status=\"5xx\"}} %d\n", c5)
	strings.write_string(&sb, "# HELP gjallarhorn_requests_in_flight Requests currently being handled.\n")
	strings.write_string(&sb, "# TYPE gjallarhorn_requests_in_flight gauge\n")
	fmt.sbprintf(&sb, "gjallarhorn_requests_in_flight %d\n", in_flight)
	strings.write_string(&sb, "# HELP gjallarhorn_request_duration_seconds Cumulative request time.\n")
	strings.write_string(&sb, "# TYPE gjallarhorn_request_duration_seconds summary\n")
	fmt.sbprintf(&sb, "gjallarhorn_request_duration_seconds_sum %f\n", dur_s)
	fmt.sbprintf(&sb, "gjallarhorn_request_duration_seconds_count %d\n", total)

	write_response(b, 200, "text/plain; version=0.0.4; charset=utf-8", strings.to_string(sb))
}

// metrics_reset zeroes every counter — for tests, and for an operator who wants
// a clean slate.
metrics_reset :: proc() {
	sync.atomic_store(&_m_total, 0)
	sync.atomic_store(&_m_2xx, 0)
	sync.atomic_store(&_m_3xx, 0)
	sync.atomic_store(&_m_4xx, 0)
	sync.atomic_store(&_m_5xx, 0)
	sync.atomic_store(&_m_in_flight, 0)
	sync.atomic_store(&_m_dur_us, 0)
}
