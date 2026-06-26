package tests

// body_decode_test.odin — JSON and urlencoded form decoders (GH-003).
// Run with: odin test ./tests

import "core:net"
import "core:strings"
import "core:testing"
import gh "../gjallarhorn"

Thing :: struct {
	id:   int,
	name: string,
}

@(test)
bind_json_ok :: proc(t: ^testing.T) {
	body := `{"id": 7, "name": "loki"}`
	b := gh.Bifrost {
		body = transmute([]u8)body,
	}
	out: Thing
	ok := gh.bind_json(&b, &out)
	testing.expect(t, ok, "valid JSON should bind")
	testing.expect_value(t, out.id, 7)
	testing.expect_value(t, out.name, "loki")
}

@(test)
bind_json_malformed_400 :: proc(t: ^testing.T) {
	server, client, paired := open_pair(t)
	if !paired {
		return
	}
	defer net.close(server)
	defer net.close(client)

	b := gh.Bifrost {
		body   = transmute([]u8)string("{not valid json"),
		client = server, // bind_json writes its 400 here on failure
	}
	out: Thing
	ok := gh.bind_json(&b, &out)
	testing.expect(t, !ok, "malformed JSON should fail to bind")

	resp: [256]u8
	n, _ := net.recv_tcp(client, resp[:])
	testing.expect(t, strings.has_prefix(string(resp[:n]), "HTTP/1.1 400"), "malformed body -> 400")
}

@(test)
form_parses_pairs :: proc(t: ^testing.T) {
	b := gh.Bifrost {
		body_text = "name=loki&id=7&blank=",
	}
	f := gh.form(&b, context.temp_allocator)
	testing.expect_value(t, f["name"], "loki")
	testing.expect_value(t, f["id"], "7")
	testing.expect_value(t, f["blank"], "")
}

@(test)
form_decodes_escapes :: proc(t: ^testing.T) {
	// '+' -> space, %2F -> '/', and a truncated escape stays literal.
	b := gh.Bifrost {
		body_text = "greet=hail+all&path=a%2Fb&bad=50%",
	}
	f := gh.form(&b, context.temp_allocator)
	testing.expect_value(t, f["greet"], "hail all")
	testing.expect_value(t, f["path"], "a/b")
	testing.expect_value(t, f["bad"], "50%")
}
