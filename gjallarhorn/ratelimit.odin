package gjallarhorn

// ratelimit.odin — a per-client token-bucket Rune. Pairs with the bounded worker
// pool (server.odin): the pool caps how much work can run at once, this caps how
// fast any one client may ask for it.
//
// Each client gets a bucket holding `rate_limit_burst` tokens that refills at
// `rate_limit_rps` per second. A request spends one token; with none left it gets
// a 429 and a `Retry-After` telling it when the next token lands. Bursts up to
// the bucket size pass untouched, so ordinary browsing (a page plus its assets)
// is never punished — only sustained excess is.
//
//   gh.rate_limit_rps   = 20   // sustained rate
//   gh.rate_limit_burst = 40   // how much burst to forgive
//   gh.rune(&app, gh.rate_limit)
//
// Runes are plain procs with no closure, so the knobs are package variables, the
// same shape as log_min_level.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

// rate_limit_rps is the sustained requests/second allowed per client.
rate_limit_rps: f64 = 10
// rate_limit_burst is the bucket capacity — the largest burst forgiven at once.
rate_limit_burst: f64 = 20
// rate_limit_trust_forwarded honors X-Forwarded-For's first entry as the client.
// Off by default: the header is trivially spoofed, so only enable it when a
// trusted reverse proxy sets it (otherwise a client picks its own bucket).
rate_limit_trust_forwarded := false

// RATE_LIMIT_IDLE_TTL drops a bucket untouched for this long, so the table
// doesn't grow without bound as clients come and go (a slow leak is its own DoS).
RATE_LIMIT_IDLE_TTL :: 300.0 // seconds
// RATE_LIMIT_SWEEP_EVERY bounds how often that eviction sweep runs.
RATE_LIMIT_SWEEP_EVERY :: 60.0 // seconds

Rate_Bucket :: struct {
	tokens: f64,
	last:   time.Tick,
}

// Workers are threads sharing one table, so every touch is mutex-guarded. Keys
// are cloned onto the heap: the caller's key is per-request temp memory, and a
// map that outlives the request must not point into a freed arena.
@(private)
_rl_mu: sync.Mutex
@(private)
_rl_buckets: map[string]Rate_Bucket
@(private)
_rl_last_sweep: time.Tick

// rate_limit is the Rune. Over-limit requests get 429 + Retry-After and never
// reach the handler.
rate_limit :: proc(b: ^Bifrost, next: Next) {
	key := client_ip(b)
	allowed, retry := rate_allow(key, time.tick_now())
	if !allowed {
		secs := int(retry) + 1 // round up; never advertise "retry in 0s"
		set_header(b, "Retry-After", fmt.tprintf("%d", secs))
		logft(.Warn, "gjallarhorn", "rate limited %s (retry in %ds)", key, secs)
		text(b, 429, "429 too many requests")
		return // do not call next
	}
	next(b)
}

// client_ip identifies the bucket a request belongs to: the peer address captured
// at accept, or the forwarded client when rate_limit_trust_forwarded is set.
client_ip :: proc(b: ^Bifrost, allocator := context.temp_allocator) -> string {
	if rate_limit_trust_forwarded {
		// X-Forwarded-For is "client, proxy1, proxy2" — the first entry is the
		// original client.
		if xff, ok := header(b, "x-forwarded-for"); ok {
			first := xff
			if c := strings.index_byte(first, ','); c >= 0 {
				first = first[:c]
			}
			first = strings.trim_space(first)
			if first != "" {
				return first
			}
		}
	}
	if b.remote.address == nil {
		return "unknown" // synthetic Bifrost (tests); one shared bucket
	}
	return net.address_to_string(b.remote.address, allocator)
}

// rate_allow spends a token for `key` at time `now`. It returns whether the
// request may proceed and, when it may not, the seconds until the next token.
// Split out from the Rune so the accounting is testable without a socket.
rate_allow :: proc(key: string, now: time.Tick) -> (allowed: bool, retry_after: f64) {
	sync.lock(&_rl_mu)
	defer sync.unlock(&_rl_mu)

	if _rl_buckets == nil {
		_rl_buckets = make(map[string]Rate_Bucket, 64, os.heap_allocator())
		_rl_last_sweep = now
	}
	_rl_sweep(now)

	bucket, found := _rl_buckets[key]
	if !found {
		bucket = Rate_Bucket {
			tokens = rate_limit_burst,
			last   = now,
		}
	} else {
		// Refill for the time elapsed, capped at the bucket size.
		elapsed := time.duration_seconds(time.tick_diff(bucket.last, now))
		if elapsed > 0 {
			bucket.tokens = min(rate_limit_burst, bucket.tokens + elapsed * rate_limit_rps)
			bucket.last = now
		}
	}

	if bucket.tokens >= 1 {
		bucket.tokens -= 1
		allowed = true
	} else {
		retry_after = (1 - bucket.tokens) / rate_limit_rps
	}

	if found {
		_rl_buckets[key] = bucket // key already owned by the map
	} else {
		_rl_buckets[strings.clone(key, os.heap_allocator())] = bucket
	}
	return
}

// _rl_sweep evicts buckets idle past the TTL. Called under the lock, at most
// every RATE_LIMIT_SWEEP_EVERY seconds. Keys are collected first, then removed —
// mutating a map mid-iteration is not safe.
@(private)
_rl_sweep :: proc(now: time.Tick) {
	if time.duration_seconds(time.tick_diff(_rl_last_sweep, now)) < RATE_LIMIT_SWEEP_EVERY {
		return
	}
	_rl_last_sweep = now

	stale := make([dynamic]string, 0, 16, context.temp_allocator)
	for k, bucket in _rl_buckets {
		if time.duration_seconds(time.tick_diff(bucket.last, now)) > RATE_LIMIT_IDLE_TTL {
			append(&stale, k)
		}
	}
	for k in stale {
		delete_key(&_rl_buckets, k)
		delete_string(k, os.heap_allocator()) // free the clone; package `delete` is the route verb
	}
}

// rate_limit_reset clears every bucket — for tests, and for an operator who wants
// a clean slate after retuning the knobs.
rate_limit_reset :: proc() {
	sync.lock(&_rl_mu)
	defer sync.unlock(&_rl_mu)
	for k, _ in _rl_buckets {
		delete_string(k, os.heap_allocator())
	}
	clear(&_rl_buckets)
}
