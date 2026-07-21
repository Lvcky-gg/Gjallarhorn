package tests

// observ_test.odin — the request_id and metrics Runes (observ.odin). Run with:
// odin test ./tests

import "core:net"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

obs_ran: bool
obs_next :: proc(b: ^gh.Bifrost) {obs_ran = true}
// A next that sets a chosen status, so metrics can bucket it.
obs_status: int
obs_status_next :: proc(b: ^gh.Bifrost) {b.status = obs_status}

@(test)
request_id_minted_and_echoed :: proc(t: ^testing.T) {
	b := gh.Bifrost{method = .Get, path = "/x"}
	b.req_headers = make(map[string]string, context.temp_allocator)
	obs_ran = false

	gh.request_id(&b, obs_next)

	testing.expect(t, obs_ran, "the chain continued")
	testing.expect(t, len(b.request_id) == 16, "a 16-hex id was minted")
	echoed, ok := b.headers[gh.REQUEST_ID_HEADER]
	testing.expect(t, ok, "id echoed in the response header")
	testing.expect_value(t, echoed, b.request_id)
}

@(test)
request_id_honors_inbound :: proc(t: ^testing.T) {
	// A sane upstream id is reused so a proxy's trace carries through.
	b := gh.Bifrost{method = .Get, path = "/x"}
	b.req_headers = make(map[string]string, context.temp_allocator)
	b.req_headers["x-request-id"] = "trace-abc-123"
	gh.request_id(&b, obs_next)
	testing.expect_value(t, b.request_id, "trace-abc-123")

	// A control-byte / overlong id is rejected and a fresh one minted.
	b2 := gh.Bifrost{method = .Get, path = "/x"}
	b2.req_headers = make(map[string]string, context.temp_allocator)
	b2.req_headers["x-request-id"] = "bad\r\ninjected"
	gh.request_id(&b2, obs_next)
	testing.expect(t, b2.request_id != "bad\r\ninjected", "control bytes rejected")
	testing.expect_value(t, len(b2.request_id), 16) // minted instead
}

@(test)
metrics_counts_and_exposes :: proc(t: ^testing.T) {
	// Deliberately one test proc: the counters are package globals and the suite
	// runs in parallel, so all metrics assertions live together after a reset.
	gh.metrics_reset()

	run :: proc(status: int) {
		obs_status = status
		b := gh.Bifrost{method = .Get, path = "/work"}
		gh.metrics(&b, obs_status_next)
	}
	run(200);run(201);run(404);run(503)

	// Scrape /metrics through the rune and read the exposition off the socket.
	server, client, ok := open_pair(t)
	if !ok {return}
	defer net.close(server)
	defer net.close(client)
	mb := gh.Bifrost{method = .Get, path = "/metrics", client = server}
	gh.metrics(&mb, obs_status_next) // short-circuits; next is not called
	buf: [4096]u8
	n, _ := net.recv_tcp(client, buf[:])
	body := string(buf[:n])

	testing.expect(t, strings.contains(body, "version=0.0.4"), "prometheus content type")
	testing.expect(t, strings.contains(body, "gjallarhorn_requests_total{status=\"2xx\"} 2"), "two 2xx")
	testing.expect(t, strings.contains(body, "gjallarhorn_requests_total{status=\"4xx\"} 1"), "one 4xx")
	testing.expect(t, strings.contains(body, "gjallarhorn_requests_total{status=\"5xx\"} 1"), "one 5xx")
	testing.expect(t, strings.contains(body, "gjallarhorn_requests_in_flight 0"), "none in flight after")
	testing.expect(t, strings.contains(body, "gjallarhorn_request_duration_seconds_count 4"), "4 timed")
	// The /metrics scrape itself was not counted.
	testing.expect(t, !strings.contains(body, "\"2xx\"} 3"), "scrape excluded from its own counts")
}
