package tests

// bind_test.odin — configurable bind address resolution (GH-012).
// Run with: odin test ./tests

import "core:net"
import "core:testing"
import gh "../gjallarhorn"

@(test)
bind_address_resolves :: proc(t: ^testing.T) {
	// Empty host -> loopback.
	loop, _ := gh.bind_address("").(net.IP4_Address)
	testing.expect_value(t, loop, net.IP4_Loopback)

	// A valid address is used as-is.
	all, ok := gh.bind_address("0.0.0.0").(net.IP4_Address)
	testing.expect(t, ok, "0.0.0.0 should parse as IPv4")
	testing.expect_value(t, all, net.IP4_Address{0, 0, 0, 0})

	specific, _ := gh.bind_address("192.168.1.5").(net.IP4_Address)
	testing.expect_value(t, specific, net.IP4_Address{192, 168, 1, 5})

	// Garbage falls back to loopback rather than binding everything.
	fallback, _ := gh.bind_address("not-an-ip").(net.IP4_Address)
	testing.expect_value(t, fallback, net.IP4_Loopback)
}
