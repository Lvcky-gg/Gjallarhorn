package tests

// worker_default_test.odin — the connection worker pool is sized relative to the
// machine (a benchmark found a fixed 256 oversubscribes small boxes). We can't
// assert an exact count (it depends on cores), only that it lands in the sane
// clamped range, and that an explicit Config.workers still wins. Run with:
// odin test ./tests

import "core:testing"
import gh "../gjallarhorn"

@(test)
worker_default_is_core_relative :: proc(t: ^testing.T) {
	n := gh.default_workers()
	testing.expect(t, n >= 16 && n <= 256, "default is clamped to [16, 256]")

	app := gh.new(gh.Config{})
	testing.expect_value(t, app.workers, n) // an unset Config.workers gets the default

	explicit := gh.new(gh.Config{workers = 42})
	testing.expect_value(t, explicit.workers, 42) // an explicit value overrides
}
