package tests

// ratelimit_test.odin — the per-client token-bucket Rune. `rate_allow` takes an
// explicit `now`, so refill and expiry are tested with a simulated clock rather
// than sleeping. Run with: odin test ./tests

import "core:testing"
import "core:time"
import gh "../gjallarhorn"

// The Rune needs a Next; Odin has no closures, so the probe counter is a package
// variable.
rl_next_calls: int
rl_noop_next :: proc(b: ^gh.Bifrost) {rl_next_calls += 1}

@(test)
rate_limit_token_bucket :: proc(t: ^testing.T) {
	// Deliberately one test proc: the knobs are package globals and the suite runs
	// tests in parallel, so keeping every rate-limit assertion here keeps them
	// deterministic. Each case uses its own key, so buckets never collide.
	gh.rate_limit_rps = 10
	gh.rate_limit_burst = 3

	base := time.tick_now()

	// (a) A burst up to the bucket size passes untouched.
	for i in 0 ..< 3 {
		ok, _ := gh.rate_allow("k-burst", base)
		testing.expectf(t, ok, "request %d within the burst should pass", i + 1)
	}

	// (b) The next one is refused, and says when to come back: one token at
	//     10/sec is 0.1s away.
	ok4, retry := gh.rate_allow("k-burst", base)
	testing.expect(t, !ok4, "the 4th request exceeds a burst of 3")
	testing.expectf(t, retry > 0.05 && retry < 0.15, "retry_after ~= 1/rps, got %v", retry)

	// (c) Refill is proportional to elapsed time: 0.2s at 10/sec = 2 tokens.
	later := time.tick_add(base, 200 * time.Millisecond)
	a1, _ := gh.rate_allow("k-burst", later)
	a2, _ := gh.rate_allow("k-burst", later)
	a3, _ := gh.rate_allow("k-burst", later)
	testing.expect(t, a1 && a2, "0.2s at 10rps refills two tokens")
	testing.expect(t, !a3, "...but only two")

	// (d) Buckets are per client, so one noisy caller can't starve another.
	other, _ := gh.rate_allow("k-other", base)
	testing.expect(t, other, "a different client gets its own full bucket")

	// (e) Refill is capped at the bucket size — idling doesn't bank tokens
	//     forever (60s at 10/sec would be 600 without the cap).
	much_later := time.tick_add(base, 60 * time.Second)
	allowed := 0
	for i in 0 ..< 10 {
		if ok, _ := gh.rate_allow("k-burst", much_later); ok {
			allowed += 1
		} else {
			break
		}
	}
	testing.expect_value(t, allowed, 3)

	// (f) The Rune itself: an over-limit request gets 429 + Retry-After and never
	//     reaches the handler. This lives in the same proc as the accounting
	//     above on purpose — the knobs are package globals, so two rate-limit
	//     tests running in parallel would read each other's settings.
	gh.rate_limit_rps = 1
	gh.rate_limit_burst = 1
	rl_next_calls = 0

	b1 := gh.Bifrost {
		method = .Get,
		path   = "/x",
	}
	gh.rate_limit(&b1, rl_noop_next) // spends the only token
	testing.expect_value(t, rl_next_calls, 1)

	b2 := gh.Bifrost {
		method = .Get,
		path   = "/x",
	}
	gh.rate_limit(&b2, rl_noop_next)
	testing.expect_value(t, b2.status, 429)
	testing.expect_value(t, rl_next_calls, 1) // short-circuited: handler not reached

	_, has_retry := b2.headers["Retry-After"]
	testing.expect(t, has_retry, "a 429 carries Retry-After")
}
