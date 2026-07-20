package tests

// password_test.odin — Argon2id password hashing (password.odin). Uses a reduced
// cost so the suite stays fast; the shipped default is OWASP's parameter set.
// Run with: odin test ./tests

import "core:crypto/argon2id"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

// Cheap-but-real parameters: still Argon2id, just not 19 MiB per call.
@(init)
password_test_cost :: proc "contextless" () {
	gh.PASSWORD_PARAMS = argon2id.Parameters {
		memory_size = 64, // KiB
		passes      = 1,
		parallelism = 1,
	}
}

@(test)
password_hash_verifies :: proc(t: ^testing.T) {
	hash, ok := gh.hash_password("horse battery staple", context.temp_allocator)
	testing.expect(t, ok, "hashing succeeds")
	testing.expect(t, gh.verify_password("horse battery staple", hash), "the right password verifies")
	testing.expect(t, !gh.verify_password("wrong", hash), "a wrong password does not")
	testing.expect(t, !gh.verify_password("", hash), "an empty password does not")
}

@(test)
password_hash_is_salted :: proc(t: ^testing.T) {
	// The same password hashed twice must differ (fresh salt each time), yet both
	// must verify — that's what stops a stolen table from being rainbow-tabled.
	a, ok1 := gh.hash_password("same", context.temp_allocator)
	b, ok2 := gh.hash_password("same", context.temp_allocator)
	testing.expect(t, ok1 && ok2)
	testing.expect(t, a != b, "each hash carries its own random salt")
	testing.expect(t, gh.verify_password("same", a) && gh.verify_password("same", b))
}

@(test)
password_hash_is_phc_format :: proc(t: ^testing.T) {
	// The stored string is a standard PHC record: the algorithm, version, and
	// cost travel with the hash, which is what lets old hashes keep verifying.
	hash, _ := gh.hash_password("x", context.temp_allocator)
	testing.expect(t, strings.has_prefix(hash, "$argon2id$v=19$m="), "PHC prefix")

	parts := strings.split(hash, "$", context.temp_allocator)
	testing.expect_value(t, len(parts), 6) // "", argon2id, v=19, params, salt, hash
	testing.expect_value(t, parts[1], "argon2id")
	testing.expect(t, strings.contains(parts[3], "t="), "cost is recorded")
	testing.expect(t, len(parts[4]) > 0 && len(parts[5]) > 0, "salt and tag present")
	// PHC base64 carries no '=' padding (the params field legitimately has '=').
	testing.expect(
		t,
		!strings.has_suffix(parts[4], "=") && !strings.has_suffix(parts[5], "="),
		"base64 is unpadded",
	)
}

@(test)
password_verify_survives_cost_change :: proc(t: ^testing.T) {
	// A hash made at one cost must still verify after the default is raised —
	// the parameters come from the stored record, not the current global.
	old_hash, ok := gh.hash_password("legacy", context.temp_allocator)
	testing.expect(t, ok)

	restore := gh.PASSWORD_PARAMS
	gh.PASSWORD_PARAMS = argon2id.Parameters {
		memory_size = 128,
		passes      = 2,
		parallelism = 1,
	}
	testing.expect(t, gh.verify_password("legacy", old_hash), "old hash still verifies at the new cost")
	gh.PASSWORD_PARAMS = restore
}

@(test)
password_rejects_malformed_hashes :: proc(t: ^testing.T) {
	// Every malformed record must deny, never crash or accidentally admit.
	for bad in ([]string {
			"",
			"not-a-hash",
			"$argon2id$",
			"$argon2i$v=19$m=64,t=1,p=1$c2FsdA$aGFzaA", // wrong algorithm
			"$argon2id$v=99$m=64,t=1,p=1$c2FsdA$aGFzaA", // unknown version
			"$argon2id$v=19$m=0,t=0,p=0$c2FsdA$aGFzaA", // degenerate cost
			"$argon2id$v=19$m=64,t=1,p=1$$", // empty salt/tag
		}) {
		testing.expectf(t, !gh.verify_password("x", bad), "must reject %q", bad)
	}
}
