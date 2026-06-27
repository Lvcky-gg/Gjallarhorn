package gjallarhorn

// tls.odin — optional TLS, shared by the Postgres client (GH-031) and the HTTP
// server (GH-054). Odin ships no TLS in core or vendor, so this binds the system
// OpenSSL (libssl/libcrypto) through `foreign import`.
//
// To keep that dependency off anyone who doesn't want it, the whole binding plus
// the SSL code lives behind `when GJ_TLS`. In a default build (GJ_TLS=false)
// nothing links libssl, OpenSSL need not even be installed, and the stub helpers
// compile in its place — every TLS branch in postgres.odin / server.odin is dead
// code that is never reached because no `ssl` pointer is ever set. Build with
// `-define:GJ_TLS=true` to pull OpenSSL in.
//
// OpenSSL works on the socket's file descriptor: hand it the fd via SSL_set_fd,
// run the handshake (SSL_connect as a client, SSL_accept as a server), then route
// all reads/writes through SSL_read/SSL_write.

import "core:c"
import "core:fmt"
import "core:net"
import "core:strings"

// GJ_TLS is the compile-time switch. It is always defined (even in non-TLS
// builds) so callers can branch on it to give a clear "rebuild" error. The
// core:c/fmt/strings imports are used only inside `when GJ_TLS`; Odin does not
// flag them as unused when the block is disabled.
GJ_TLS :: #config(GJ_TLS, false)

when GJ_TLS {

	foreign import lib_ssl "system:ssl"

	// Constants from the OpenSSL headers (stable across 1.1.x and 3.x).
	SSL_VERIFY_PEER :: 1
	SSL_FILETYPE_PEM :: 1
	X509_V_OK :: 0
	// SSL_set_tlsext_host_name (SNI) is a header macro over SSL_ctrl; bind the
	// underlying call with its control id.
	SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
	TLSEXT_NAMETYPE_host_name :: 0

	@(default_calling_convention = "c")
	foreign lib_ssl {
		TLS_client_method :: proc() -> rawptr ---
		TLS_server_method :: proc() -> rawptr ---
		SSL_CTX_new :: proc(method: rawptr) -> rawptr ---
		SSL_CTX_free :: proc(ctx: rawptr) ---
		SSL_CTX_set_verify :: proc(ctx: rawptr, mode: c.int, cb: rawptr) ---
		SSL_CTX_set_default_verify_paths :: proc(ctx: rawptr) -> c.int ---
		SSL_CTX_use_certificate_chain_file :: proc(ctx: rawptr, file: cstring) -> c.int ---
		SSL_CTX_use_PrivateKey_file :: proc(ctx: rawptr, file: cstring, type: c.int) -> c.int ---
		SSL_CTX_check_private_key :: proc(ctx: rawptr) -> c.int ---
		SSL_new :: proc(ctx: rawptr) -> rawptr ---
		SSL_free :: proc(ssl: rawptr) ---
		SSL_set_fd :: proc(ssl: rawptr, fd: c.int) -> c.int ---
		SSL_set1_host :: proc(ssl: rawptr, hostname: cstring) -> c.int ---
		SSL_ctrl :: proc(ssl: rawptr, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
		SSL_connect :: proc(ssl: rawptr) -> c.int ---
		SSL_accept :: proc(ssl: rawptr) -> c.int ---
		SSL_read :: proc(ssl: rawptr, buf: rawptr, num: c.int) -> c.int ---
		SSL_write :: proc(ssl: rawptr, buf: rawptr, num: c.int) -> c.int ---
		SSL_get_verify_result :: proc(ssl: rawptr) -> c.long ---
		SSL_shutdown :: proc(ssl: rawptr) -> c.int ---
	}

	// tls_client_connect upgrades an already-connected socket to TLS as the
	// client. `verify` true enforces certificate chain + hostname validation
	// (sslmode=verify-full); false trusts any certificate (require). Returns the
	// SSL* on success.
	tls_client_connect :: proc(sock: net.TCP_Socket, host: string, verify: bool) -> (rawptr, bool) {
		ctx := SSL_CTX_new(TLS_client_method())
		if ctx == nil {
			fmt.eprintln("tls: SSL_CTX_new failed")
			return nil, false
		}
		if verify {
			SSL_CTX_set_default_verify_paths(ctx) // load the system CA bundle
			SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
		}
		ssl := SSL_new(ctx)
		SSL_CTX_free(ctx) // SSL_new took a ref; ctx lives until SSL_free
		if ssl == nil {
			fmt.eprintln("tls: SSL_new failed")
			return nil, false
		}
		if SSL_set_fd(ssl, c.int(sock)) != 1 {
			fmt.eprintln("tls: SSL_set_fd failed")
			SSL_free(ssl)
			return nil, false
		}

		host_c := strings.clone_to_cstring(host, context.temp_allocator)
		// Always send SNI so name-based TLS front ends route correctly.
		SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(host_c))
		if verify {
			// Arms in-handshake hostname matching; SSL_connect then fails on mismatch.
			SSL_set1_host(ssl, host_c)
		}

		if SSL_connect(ssl) != 1 {
			fmt.eprintfln("tls: handshake with %s failed", host)
			SSL_free(ssl)
			return nil, false
		}
		if verify && SSL_get_verify_result(ssl) != X509_V_OK {
			fmt.eprintfln("tls: certificate verification for %s failed", host)
			SSL_shutdown(ssl)
			SSL_free(ssl)
			return nil, false
		}
		return ssl, true
	}

	// tls_server_ctx builds a reusable server SSL_CTX from a PEM cert chain and
	// private key. It is created once at startup and shared by every accepted
	// connection. Returns nil/false (with a logged reason) if the files are
	// missing, malformed, or the key does not match the certificate.
	tls_server_ctx :: proc(cert_file, key_file: string) -> (rawptr, bool) {
		ctx := SSL_CTX_new(TLS_server_method())
		if ctx == nil {
			fmt.eprintln("tls: SSL_CTX_new (server) failed")
			return nil, false
		}
		cert_c := strings.clone_to_cstring(cert_file, context.temp_allocator)
		key_c := strings.clone_to_cstring(key_file, context.temp_allocator)
		if SSL_CTX_use_certificate_chain_file(ctx, cert_c) != 1 {
			fmt.eprintfln("tls: cannot load certificate %q", cert_file)
			SSL_CTX_free(ctx)
			return nil, false
		}
		if SSL_CTX_use_PrivateKey_file(ctx, key_c, SSL_FILETYPE_PEM) != 1 {
			fmt.eprintfln("tls: cannot load private key %q", key_file)
			SSL_CTX_free(ctx)
			return nil, false
		}
		if SSL_CTX_check_private_key(ctx) != 1 {
			fmt.eprintln("tls: private key does not match the certificate")
			SSL_CTX_free(ctx)
			return nil, false
		}
		return ctx, true
	}

	// tls_server_accept performs the server-side handshake on a freshly accepted
	// socket using the shared ctx. Returns the SSL* for this connection.
	tls_server_accept :: proc(ctx: rawptr, sock: net.TCP_Socket) -> (rawptr, bool) {
		ssl := SSL_new(ctx)
		if ssl == nil {
			return nil, false
		}
		if SSL_set_fd(ssl, c.int(sock)) != 1 {
			SSL_free(ssl)
			return nil, false
		}
		if SSL_accept(ssl) != 1 {
			SSL_free(ssl)
			return nil, false
		}
		return ssl, true
	}

	// tls_send writes the whole buffer through the TLS session.
	tls_send :: proc(ssl: rawptr, buf: []u8) -> bool {
		off := 0
		for off < len(buf) {
			n := SSL_write(ssl, raw_data(buf[off:]), c.int(len(buf) - off))
			if n <= 0 {
				return false
			}
			off += int(n)
		}
		return true
	}

	// tls_recv reads up to len(dst) bytes; returns (0, false) on error/close.
	tls_recv :: proc(ssl: rawptr, dst: []u8) -> (int, bool) {
		n := SSL_read(ssl, raw_data(dst), c.int(len(dst)))
		if n <= 0 {
			return 0, false
		}
		return int(n), true
	}

	// tls_ctx_free releases a server SSL_CTX at shutdown.
	tls_ctx_free :: proc(ctx: rawptr) {
		if ctx != nil {
			SSL_CTX_free(ctx)
		}
	}

	// tls_free tears a per-connection TLS session down before its socket closes.
	tls_free :: proc(ssl: rawptr) {
		if ssl != nil {
			SSL_shutdown(ssl)
			SSL_free(ssl)
		}
	}

} else {

	// Non-TLS build: stubs so the package compiles. None of these run, because no
	// code path sets an `ssl` pointer without a TLS build behind it.
	tls_client_connect :: proc(sock: net.TCP_Socket, host: string, verify: bool) -> (rawptr, bool) {
		return nil, false
	}
	tls_server_ctx :: proc(cert_file, key_file: string) -> (rawptr, bool) {
		return nil, false
	}
	tls_server_accept :: proc(ctx: rawptr, sock: net.TCP_Socket) -> (rawptr, bool) {
		return nil, false
	}
	tls_send :: proc(ssl: rawptr, buf: []u8) -> bool {return false}
	tls_recv :: proc(ssl: rawptr, dst: []u8) -> (int, bool) {return 0, false}
	tls_ctx_free :: proc(ctx: rawptr) {}
	tls_free :: proc(ssl: rawptr) {}
}

// pg_tls_* are thin Postgres-side wrappers over the generic helpers, keeping
// postgres.odin's call sites (which carry a ^Pg_Conn) readable. They compile in
// every build because tls_* exist in both branches above.

pg_tls_handshake :: proc(conn: ^Pg_Conn, host: string, verify: bool) -> bool {
	ssl, ok := tls_client_connect(conn.sock, host, verify)
	if !ok {
		return false
	}
	conn.ssl = ssl
	conn.tls = true
	return true
}

pg_tls_send :: proc(conn: ^Pg_Conn, buf: []u8) -> bool {
	return tls_send(conn.ssl, buf)
}

pg_tls_recv :: proc(conn: ^Pg_Conn, dst: []u8) -> (int, bool) {
	return tls_recv(conn.ssl, dst)
}

pg_tls_close :: proc(conn: ^Pg_Conn) {
	tls_free(conn.ssl)
	conn.ssl = nil
	conn.tls = false
}
