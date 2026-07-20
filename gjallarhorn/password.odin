package gjallarhorn

// password.odin — password hashing, so `login` has something safe to verify
// against. auth.odin deliberately says "call login() after you verify a
// password"; this is that verification, rather than leaving every app to invent
// its own (the classic place a site gets breached).
//
// Argon2id (RFC 9106) with the OWASP-recommended parameters, a fresh 16-byte
// CSPRNG salt per password, and a constant-time comparison. The output is a
// standard PHC string, so the salt and cost live with the hash and old hashes
// keep verifying after you raise the cost:
//
//   $argon2id$v=19$m=19456,t=2,p=1$<salt-b64>$<hash-b64>
//
// Usage — hash at signup, verify at login:
//
//   stored, ok := gh.hash_password(form["password"])    // -> store this string
//   ...
//   if gh.verify_password(form["password"], stored) {
//       gh.login(b, user_id)
//   }
//
// Hashing is *meant* to be slow (~19 MiB and a few ms per call), which also
// makes a login endpoint a natural DoS target — pair it with the `rate_limit`
// rune (ratelimit.odin).

import "core:crypto"
import "core:crypto/argon2id"
import "core:encoding/base64"
import "core:strconv"
import "core:strings"

// PASSWORD_PARAMS is the cost used for new hashes: OWASP's recommended Argon2id
// set (19 MiB, 2 passes, 1 lane). Raise it as hardware improves — existing
// hashes carry their own parameters and keep verifying.
PASSWORD_PARAMS := argon2id.PARAMS_OWASP

// PASSWORD_SALT_SIZE / PASSWORD_HASH_SIZE follow the RFC 9106 recommendations.
PASSWORD_SALT_SIZE :: argon2id.RECOMMENDED_SALT_SIZE // 16 bytes
PASSWORD_HASH_SIZE :: 32

// hash_password derives an Argon2id hash of `password` with a fresh random salt
// and returns it as a PHC string safe to store verbatim. The result lives in
// `allocator` (per-request temp by default) — clone it if it must outlive the
// request. ok=false means the derivation could not allocate its working memory;
// never store the empty result.
hash_password :: proc(
	password: string,
	allocator := context.temp_allocator,
) -> (
	hash: string,
	ok: bool,
) {
	salt: [PASSWORD_SALT_SIZE]u8
	crypto.rand_bytes(salt[:])

	tag: [PASSWORD_HASH_SIZE]u8
	params := PASSWORD_PARAMS
	// Argon2id's working memory is megabytes — never the per-request temp arena.
	if err := argon2id.derive(
		&params,
		transmute([]u8)password,
		salt[:],
		tag[:],
		allocator = context.allocator,
	); err != nil {
		logft(.Error, "gjallarhorn", "argon2id derive failed: %v", err)
		return "", false
	}
	return phc_encode(params, salt[:], tag[:], allocator), true
}

// verify_password reports whether `password` matches a stored PHC hash. The
// cost and salt come from the hash itself, so hashes made with older parameters
// still verify. The comparison is constant time; a malformed hash — or a failed
// derivation — is false, so every error path denies.
verify_password :: proc(password: string, encoded: string) -> bool {
	params, salt, want, ok := phc_decode(encoded, context.temp_allocator)
	if !ok {
		return false
	}
	got := make([]u8, len(want), context.temp_allocator)
	p := params
	if err := argon2id.derive(
		&p,
		transmute([]u8)password,
		salt,
		got,
		allocator = context.allocator,
	); err != nil {
		logft(.Error, "gjallarhorn", "argon2id derive failed: %v", err)
		return false
	}
	return crypto.compare_constant_time(got, want) == 1
}

// ---------------------------------------------------------------------------
// PHC string format — $argon2id$v=19$m=<KiB>,t=<passes>,p=<lanes>$<salt>$<hash>
// Base64 is standard-alphabet and unpadded, per the PHC spec.
// ---------------------------------------------------------------------------

// PHC_VERSION is Argon2's version field (0x13 == 19), the only one RFC 9106 defines.
PHC_VERSION :: 19

@(private)
phc_encode :: proc(
	params: argon2id.Parameters,
	salt, tag: []u8,
	allocator := context.temp_allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "$argon2id$v=")
	strings.write_int(&b, PHC_VERSION)
	strings.write_string(&b, "$m=")
	strings.write_uint(&b, uint(params.memory_size))
	strings.write_string(&b, ",t=")
	strings.write_uint(&b, uint(params.passes))
	strings.write_string(&b, ",p=")
	strings.write_uint(&b, uint(params.parallelism))
	strings.write_byte(&b, '$')
	strings.write_string(&b, b64_nopad_encode(salt, allocator))
	strings.write_byte(&b, '$')
	strings.write_string(&b, b64_nopad_encode(tag, allocator))
	return strings.to_string(b)
}

@(private)
phc_decode :: proc(
	encoded: string,
	allocator := context.temp_allocator,
) -> (
	params: argon2id.Parameters,
	salt, tag: []u8,
	ok: bool,
) {
	// "" / "argon2id" / "v=19" / "m=..,t=..,p=.." / salt / hash
	parts := strings.split(encoded, "$", allocator)
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" {
		return {}, nil, nil, false
	}
	if !strings.has_prefix(parts[2], "v=") {
		return {}, nil, nil, false
	}
	if v, vok := strconv.parse_int(parts[2][2:]); !vok || v != PHC_VERSION {
		return {}, nil, nil, false
	}

	for field in strings.split(parts[3], ",", allocator) {
		if len(field) < 3 || field[1] != '=' {
			return {}, nil, nil, false
		}
		n, nok := strconv.parse_uint(field[2:])
		if !nok {
			return {}, nil, nil, false
		}
		switch field[0] {
		case 'm':
			params.memory_size = u32(n)
		case 't':
			params.passes = u32(n)
		case 'p':
			params.parallelism = u32(n)
		case:
			return {}, nil, nil, false
		}
	}
	// Reject a cost Argon2id would panic on rather than crash the handler.
	if params.memory_size < 8 || params.passes < 1 || params.parallelism < 1 {
		return {}, nil, nil, false
	}

	sok, tok: bool
	if salt, sok = b64_nopad_decode(parts[4], allocator); !sok || len(salt) == 0 {
		return {}, nil, nil, false
	}
	if tag, tok = b64_nopad_decode(parts[5], allocator); !tok || len(tag) < 4 {
		return {}, nil, nil, false
	}
	return params, salt, tag, true
}

// b64_nopad_encode is standard base64 with the '=' padding stripped (PHC style).
@(private)
b64_nopad_encode :: proc(src: []u8, allocator := context.temp_allocator) -> string {
	s := base64.encode(src, base64.ENC_TABLE, allocator)
	return strings.trim_right(s, "=")
}

// b64_nopad_decode restores the stripped padding before decoding.
@(private)
b64_nopad_decode :: proc(s: string, allocator := context.temp_allocator) -> ([]u8, bool) {
	padded := s
	if pad := (4 - len(s) % 4) % 4; pad > 0 {
		padded = strings.concatenate({s, strings.repeat("=", pad, allocator)}, allocator)
	}
	out, err := base64.decode(padded, base64.DEC_TABLE, nil, allocator)
	return out, err == nil
}
